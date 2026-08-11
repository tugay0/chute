import AppKit

/// Two-way mirror between a local folder (default ~/Chute) and remote-box:~/inbox.
///
/// rsync moves only the diff (never blanket, so deletes aren't resurrected); we
/// classify each path against a saved base snapshot. Deletes are non-destructive
/// (Trash locally / `.chute-trash` on the server) and overwrites are backed up.
/// Safety rails: abort on a failed/missing scan, never delete off an unexpectedly
/// empty local scan, a circuit breaker that holds (only) large delete batches,
/// and serialized cycles.
final class FolderSync {
    static let shared = FolderSync()

    struct Meta: Codable { let size: Int64; let mtime: Double }

    private let q = DispatchQueue(label: "com.github.tugay0.chute.foldersync")
    private var timer: Timer?
    private var running = false          // main-thread only
    private let stateURL: URL

    private(set) var statusText = "Folder sync off"

    private init() {
        stateURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Chute/syncstate.json")
    }

    // MARK: - Lifecycle

    func reload() {
        timer?.invalidate(); timer = nil
        guard Config.syncEnabled else { statusText = "Folder sync off"; return }
        try? FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
        statusText = "Folder sync starting…"
        syncNow()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in self?.syncNow() }
        timer?.tolerance = 1
    }

    func syncNow() {
        guard Config.syncEnabled, !running else { return }
        running = true
        q.async {
            self.runCycle()
            DispatchQueue.main.async { self.running = false }
        }
    }

    // MARK: - Paths

    private var mirrorRoot: URL { URL(fileURLWithPath: Config.mirrorPath, isDirectory: true) }
    private var remoteSpec: String { "\(Config.host):\(remoteDir)/" }   // remote-box:inbox/

    /// Remote dir relative to $HOME, sanitized so it can't inject into the ssh
    /// command string (falls back to "inbox" if it contains anything unusual).
    private var remoteDir: String {
        var f = Config.folder
        if f.hasSuffix("/") { f.removeLast() }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        let safe = !f.isEmpty && f.unicodeScalars.allSatisfy { allowed.contains($0) } && !f.contains("..")
        return safe ? f : "inbox"
    }

    // MARK: - Cycle (background queue)

    private func runCycle() {
        guard Config.syncEnabled else { return }
        let root = mirrorRoot

        // Do NOT recreate the folder here — if it's gone (user moved it), scanLocal
        // must fail so we abort rather than mass-deleting the remote.
        let (localOK, local) = scanLocal(root)
        guard localOK else { setStatus("Sync paused — local folder missing"); return }
        let (remoteOK, remote) = scanRemote()
        guard remoteOK else { setStatus("Sync — server offline"); return }
        let base = loadBase()

        // An empty local scan while the base had files means the folder was moved/
        // wiped out from under us, not a deliberate "delete everything" → repopulate.
        let suspiciousEmpty = local.isEmpty && base.count > 0

        var download: [String] = [], upload: [String] = []
        var delLocal: [String] = [], delRemote: [String] = []
        for rel in Set(local.keys).union(remote.keys).union(base.keys) {
            let l = local[rel], r = remote[rel], b = base[rel]
            switch (l, r) {
            case let (l?, r?):
                if same(l, r) { continue }
                if l.mtime >= r.mtime { upload.append(rel) } else { download.append(rel) }
            case (let l?, nil):
                if let b = b, same(l, b) { delLocal.append(rel) } else { upload.append(rel) }
            case (nil, let r?):
                if let b = b, same(r, b) { delRemote.append(rel) } else { download.append(rel) }
            case (nil, nil):
                continue
            }
        }

        // Deletes we intentionally do NOT apply this cycle, but must keep in the
        // base so they aren't re-added (resurrected) as new files.
        var heldDeletes: [String] = []
        if suspiciousEmpty {
            heldDeletes += delLocal + delRemote
            delLocal.removeAll(); delRemote.removeAll()
        }
        var holdMsg = false
        let deleteCount = delLocal.count + delRemote.count
        if base.count >= 8 && deleteCount > base.count / 2 {
            holdMsg = true
            heldDeletes += delLocal + delRemote
            delLocal.removeAll(); delRemote.removeAll()
        }

        if download.isEmpty && upload.isEmpty && delLocal.isEmpty && delRemote.isEmpty && !holdMsg {
            setStatus("Synced · \(base.count) in sync"); return
        }
        setStatus("Syncing…")

        trashLocal(delLocal, root: root)
        trashRemote(delRemote)
        rsyncFiles(download, down: true, root: root)     // remote → local
        rsyncFiles(upload, down: false, root: root)      // local → remote

        // Base = files confirmed in-sync on BOTH sides, PLUS carry-forward of any
        // targeted-or-held delete still present on a side (so it retries, never
        // gets re-added). A delete that fully applied is absent from both → dropped.
        let (lok, l2) = scanLocal(root)
        let (rok, r2) = scanRemote()
        if lok && rok {
            var base2: [String: Meta] = [:]
            for (k, lv) in l2 where r2[k].map({ same(lv, $0) }) == true { base2[k] = lv }
            for rel in delLocal + delRemote + heldDeletes where base2[rel] == nil {
                if let old = base[rel], l2[rel] != nil || r2[rel] != nil { base2[rel] = old }
            }
            saveBase(base2)
            setStatus(holdMsg ? "Held \(heldDeletes.count) deletions (safety)"
                              : "Synced · \(base2.count) in sync")
        }
    }

    private func same(_ a: Meta, _ b: Meta) -> Bool { a.size == b.size && abs(a.mtime - b.mtime) < 3 }

    // MARK: - Scans

    private func scanLocal(_ root: URL) -> (Bool, [String: Meta]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return (false, [:])   // missing/moved folder → abort the cycle
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return (false, [:]) }
        var out: [String: Meta] = [:]
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in en {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
            guard url.path.hasPrefix(prefix) else { continue }
            out[String(url.path.dropFirst(prefix.count))] = Meta(
                size: Int64(rv.fileSize ?? 0),
                mtime: rv.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return (true, out)
    }

    private func scanRemote() -> (Bool, [String: Meta]) {
        // Exclude hidden files at ANY level ('*/.*'), matching scanLocal's
        // skipsHiddenFiles — otherwise nested dotfiles (e.g. references/.DS_Store)
        // are seen by the server but not locally and re-download every cycle.
        let cmd = "cd \"$HOME/\(remoteDir)\" 2>/dev/null && find . -type f -not -path '*/.*' -printf '%P\\t%s\\t%T@\\n'"
        let p = Process()
        p.environment = childEnv()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", Config.host, cmd]
        let out = Pipe(); p.standardOutput = out
        p.standardError = FileHandle.nullDevice          // don't let stderr fill a pipe
        do { try p.run() } catch { return (false, [:]) }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // drain before wait
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return (false, [:]) }

        var result: [String: Meta] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let size = Int64(parts[1]), let mtime = Double(parts[2]) else { continue }
            result[String(parts[0])] = Meta(size: size, mtime: mtime)
        }
        return (true, result)
    }

    // MARK: - Transfers & deletes

    private func rsyncFiles(_ rels: [String], down: Bool, root: URL) {
        guard !rels.isEmpty else { return }
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chute-sync-\(UUID().uuidString).list")
        let payload = (rels.joined(separator: "\u{0}") + "\u{0}").data(using: .utf8) ?? Data()
        do { try payload.write(to: listURL) } catch { return }
        defer { try? FileManager.default.removeItem(at: listURL) }

        let local = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // --backup keeps any overwritten file (a genuine both-sides conflict) in
        // .chute-trash on the destination, so nothing is lost silently.
        let common = ["-az", "--from0", "--files-from=\(listURL.path)", "--backup", "--backup-dir=.chute-trash"]
        let p = Process()
        p.environment = childEnv()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = down ? common + [remoteSpec, local] : common + [local, remoteSpec]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { }
    }

    private func trashLocal(_ rels: [String], root: URL) {
        for rel in rels {
            try? FileManager.default.trashItem(at: root.appendingPathComponent(rel), resultingItemURL: nil)
        }
    }

    private func trashRemote(_ rels: [String]) {
        guard !rels.isEmpty else { return }
        let cmd = "cd \"$HOME/\(remoteDir)\" && mkdir -p .chute-trash && xargs -0 -I{} mv -f -- {} .chute-trash/ 2>/dev/null || true"
        let p = Process()
        p.environment = childEnv()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", Config.host, cmd]
        let stdin = Pipe(); p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            stdin.fileHandleForWriting.write((rels.joined(separator: "\u{0}") + "\u{0}").data(using: .utf8) ?? Data())
            stdin.fileHandleForWriting.closeFile()
            p.waitUntilExit()
        } catch { }
    }

    // MARK: - Base snapshot

    private func loadBase() -> [String: Meta] {
        guard let data = try? Data(contentsOf: stateURL),
              let base = try? JSONDecoder().decode([String: Meta].self, from: data) else { return [:] }
        return base
    }
    private func saveBase(_ base: [String: Meta]) {
        if let data = try? JSONEncoder().encode(base) { try? data.write(to: stateURL) }
    }

    // MARK: - Helpers

    private func setStatus(_ s: String) { DispatchQueue.main.async { self.statusText = s } }

    private func childEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = NSHomeDirectory()
        return env
    }
}
