import Cocoa

/// Owns the transfer queue, the connectivity heartbeat, and the offline resend
/// buffer. Default destination reuses push.sh (the /push skill's path); a custom
/// host/folder uses a direct rsync.
final class Uploader {
    static let shared = Uploader()

    private let q = DispatchQueue(label: "co.ambient.chute.upload")
    private let captureQ = DispatchQueue(label: "co.ambient.chute.capture")  // interactive; must not block transfers
    private let probeQ = DispatchQueue(label: "co.ambient.chute.probe")      // heartbeat; off the upload lane
    private var heartbeat: Timer?

    // Main-thread only.
    private var batchPaths: [String] = []       // copied to clipboard together
    private var resendBuffer: [URL] = []        // offline queue
    private var lastReachable = true            // optimistic until first probe

    let outbox: URL
    let pushScript = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/skills/push/push.sh")
    private let resendKey = "chute.resendBuffer"

    private init() {
        outbox = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Chute/outbox",
                     isDirectory: true)
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        if let paths = UserDefaults.standard.array(forKey: resendKey) as? [String] {
            resendBuffer = paths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        sweepOutbox()
    }

    /// Remove staging files (paste-*/capture-*/text-*) left behind by failed or
    /// cancelled sends, older than a few days and not currently queued for resend.
    private func sweepOutbox() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        let queued = Set(resendBuffer.map { $0.path })
        for f in files where !queued.contains(f.path) {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if mod < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    private var remoteDest: String { "\(Config.sendHost):\(Config.sendFolder)" }

    func start() {
        checkNow()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.checkNow() }
    }

    // MARK: - Enqueue (main thread)

    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if !lastReachable {                      // known offline → buffer without trying
            bufferOffline(urls, decrementPending: false)   // this path never incremented pending
            return
        }
        if Status.shared.pending == 0 { batchPaths.removeAll() }
        Status.shared.set(state: .sending,
                          pending: Status.shared.pending + urls.count,
                          message: "Queued \(urls.count)")
        q.async { for u in urls { self.run([u]) } }
    }

    func clipboardHasSendable(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if pb.availableType(from: [.png, .tiff,
                                   NSPasteboard.PasteboardType("public.jpeg"),
                                   NSPasteboard.PasteboardType("com.adobe.pdf")]) != nil { return true }
        return NSImage(pasteboard: pb) != nil
    }

    @discardableResult
    func enqueuePasteboard(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            enqueue(urls); return true
        }
        if let url = writeOriginalData(from: pb) { enqueue([url]); return true }
        if let img = NSImage(pasteboard: pb) { return enqueueImage(img) }
        Status.shared.set(state: .error, message: "Nothing to send (no file/image)")
        return false
    }

    @discardableResult
    func enqueueClipboard() -> Bool { enqueuePasteboard(NSPasteboard.general) }

    private func writeOriginalData(from pb: NSPasteboard) -> URL? {
        let flavors: [(NSPasteboard.PasteboardType, String)] = [
            (NSPasteboard.PasteboardType("com.adobe.pdf"), "pdf"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (NSPasteboard.PasteboardType("public.png"), "png"),
            (NSPasteboard.PasteboardType("public.tiff"), "tiff"),
        ]
        for (type, ext) in flavors {
            guard let data = pb.data(forType: type) else { continue }
            let dest = outbox.appendingPathComponent("paste-\(Self.stamp()).\(ext)")
            do { try data.write(to: dest); return dest } catch { return nil }
        }
        return nil
    }

    @discardableResult
    private func enqueueImage(_ img: NSImage) -> Bool {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Status.shared.set(state: .error, message: "Couldn't read image"); return false
        }
        let dest = outbox.appendingPathComponent("paste-\(Self.stamp()).png")
        do { try png.write(to: dest) }
        catch { Status.shared.set(state: .error, message: "Write failed"); return false }
        enqueue([dest]); return true
    }

    /// Interactive region screenshot → send (remote path is copied on success).
    func captureRegionAndSend() {
        let dest = outbox.appendingPathComponent("capture-\(Self.stamp()).png")
        Status.shared.set(state: .sending, message: "Select a region…")
        captureQ.async {
            let p = Process()
            p.environment = self.childEnv()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", dest.path]
            do { try p.run(); p.waitUntilExit() }
            catch { DispatchQueue.main.async { Status.shared.set(state: .error, message: "Capture failed") }; return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? Int) ?? 0
            if size > 0 {
                DispatchQueue.main.async { self.enqueue([dest]) }
            } else {
                DispatchQueue.main.async {
                    Status.shared.set(state: .idle, message: "Capture cancelled")
                    self.checkNow()
                }
            }
        }
    }

    // MARK: - Transfer (background queue)

    private func run(_ urls: [URL]) {
        let p = Process()
        p.environment = childEnv()
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe

        if Config.isDefaultSend && FileManager.default.fileExists(atPath: pushScript.path) {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [pushScript.path] + urls.map { $0.path }
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            p.arguments = ["-avz"] + urls.map { $0.path } + [remoteDest]
        }

        do { try p.run() }
        catch { DispatchQueue.main.async { self.handleError(urls, "Couldn't start rsync") }; return }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // drain before wait (no pipe deadlock)
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""

        if p.terminationStatus == 0 {
            finishOK(urls)
        } else if probeReachable() {
            DispatchQueue.main.async { self.handleError(urls, self.shortErr(out)) }
        } else {
            DispatchQueue.main.async { self.lastReachable = false; self.bufferOffline(urls) }
        }
    }

    private func finishOK(_ urls: [URL]) {
        DispatchQueue.main.async {
            self.lastReachable = true
            let name = urls.last?.lastPathComponent ?? "?"
            Status.shared.pushRecent(TransferItem(name: name, ok: true))
            let pend = max(0, Status.shared.pending - urls.count)

            self.batchPaths.append(contentsOf: urls.map { self.formatRemote($0) })
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(self.batchPaths.joined(separator: "\n"), forType: .string)
            ClipboardHistory.shared.suppress()

            Status.shared.set(state: pend > 0 ? .sending : .synced, pending: pend,
                              message: self.batchPaths.count > 1
                                  ? "Paths copied (\(self.batchPaths.count)) · \(name)"
                                  : "Path copied · \(name)")
            if Config.soundOnSend { NSSound(named: "Tink")?.play() }

            // Delete our own staging copies once delivered (not the user's dropped files).
            for u in urls where u.path.hasPrefix(self.outbox.path) {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    private func handleError(_ urls: [URL], _ msg: String) {   // main thread
        let name = urls.last?.lastPathComponent ?? "?"
        Status.shared.pushRecent(TransferItem(name: name, ok: false))
        let pend = max(0, Status.shared.pending - urls.count)
        Status.shared.set(state: .error, pending: pend, message: msg)
    }

    // MARK: - Offline queue (main thread)

    private func bufferOffline(_ urls: [URL], decrementPending: Bool = true) {
        resendBuffer.append(contentsOf: urls.filter { FileManager.default.fileExists(atPath: $0.path) })
        persistResend()
        let pend = decrementPending ? max(0, Status.shared.pending - urls.count) : Status.shared.pending
        Status.shared.set(state: .offline, pending: pend, message: "Offline — \(resendBuffer.count) queued")
    }

    private func persistResend() {
        UserDefaults.standard.set(resendBuffer.map { $0.path }, forKey: resendKey)
    }

    private func flushResend() {
        guard !resendBuffer.isEmpty else { return }
        let toSend = resendBuffer
        resendBuffer.removeAll()
        persistResend()
        enqueue(toSend)   // lastReachable is true here, so they actually send
    }

    // MARK: - Heartbeat

    func checkNow(manual: Bool = false) {
        probeQ.async {
            let ok = self.probeReachable()
            DispatchQueue.main.async {
                self.lastReachable = ok
                if Status.shared.pending > 0 { return }        // a send is in progress

                if ok {
                    // Drain whenever anything is queued, not just on the reconnect
                    // edge — the buffer can fill while already reachable (a blip
                    // mid-batch), and must never sit undelivered behind a green light.
                    if !self.resendBuffer.isEmpty { self.flushResend(); return }
                    let clearable: Set<SyncState> = manual ? [.offline, .idle, .error] : [.offline, .idle]
                    if clearable.contains(Status.shared.state) {
                        Status.shared.set(state: .synced, message: "Connected")
                    }
                } else {
                    Status.shared.set(state: .offline,
                                      message: self.resendBuffer.isEmpty ? "Server unreachable"
                                                                         : "Offline — \(self.resendBuffer.count) queued")
                }
            }
        }
    }

    private func probeReachable() -> Bool {
        let p = Process()
        p.environment = childEnv()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", Config.sendHost, "true"]
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    // MARK: - Helpers

    private func formatRemote(_ url: URL) -> String {
        Config.copyFormat
            .replacingOccurrences(of: "{name}", with: url.lastPathComponent)
            .replacingOccurrences(of: "{folder}", with: Config.sendFolder)
            .replacingOccurrences(of: "{host}", with: Config.sendHost)
    }

    private func childEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = NSHomeDirectory()
        return env
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    private func shortErr(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).last.map(String.init) ?? "transfer error"
        return String(line.prefix(52))
    }
}
