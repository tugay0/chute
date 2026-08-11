import AppKit
import Combine

/// Pinned, persistent clipboard items with optional global hotkeys. Favorites
/// survive restarts (JSON in UserDefaults; file payloads copied into a favorites
/// dir that — unlike the history dir — is never purged).
struct Favorite: Codable, Identifiable {
    var id: String
    var label: String
    var text: String?          // set for text favorites
    var file: String?          // absolute path for file/image favorites
    var keyCode: Int?
    var mods: Int?
    var hotkeyLabel: String?
}

final class Favorites: ObservableObject {
    static let shared = Favorites()

    @Published private(set) var items: [Favorite] = []
    private let dir: URL
    private let key = "chute.favorites"

    private init() {
        dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Chute/favorites",
                  isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Favorite].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Register hotkeys for all favorites that have one (call at launch).
    func registerAllHotkeys() {
        for f in items where f.keyCode != nil && f.mods != nil {
            bindHotkey(id: f.id, keyCode: UInt32(f.keyCode!), mods: UInt32(f.mods!))
        }
    }

    // MARK: - Mutations

    func pin(_ item: ClipboardHistory.Item) {
        switch item.kind {
        case .text(let s):
            items.insert(Favorite(id: UUID().uuidString, label: shortLabel(s), text: s), at: 0)
        case .file(let u), .image(let u):
            let dest = dir.appendingPathComponent("fav-\(Uploader.stamp())-\(u.lastPathComponent)")
            do { try FileManager.default.copyItem(at: u, to: dest) }
            catch {
                Status.shared.set(state: .error, message: "Couldn't pin \(u.lastPathComponent)")
                return   // don't persist a favorite pointing at a missing file
            }
            items.insert(Favorite(id: UUID().uuidString, label: "📎 " + u.lastPathComponent, file: dest.path), at: 0)
        }
        save()
    }

    func remove(_ id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let p = items[idx].file { try? FileManager.default.removeItem(atPath: p) }
        HotKeyManager.shared.unregisterFavorite(id: id)
        items.remove(at: idx)
        save()
    }

    @discardableResult
    func setHotkey(id: String, keyCode: UInt32, mods: UInt32, label: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        guard bindHotkey(id: id, keyCode: keyCode, mods: mods) else { return false }
        items[idx].keyCode = Int(keyCode); items[idx].mods = Int(mods); items[idx].hotkeyLabel = label
        save()
        return true
    }

    func clearHotkey(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        HotKeyManager.shared.unregisterFavorite(id: id)
        items[idx].keyCode = nil; items[idx].mods = nil; items[idx].hotkeyLabel = nil
        save()
    }

    @discardableResult
    private func bindHotkey(id: String, keyCode: UInt32, mods: UInt32) -> Bool {
        HotKeyManager.shared.registerFavorite(id: id, keyCode: keyCode, modifiers: mods) { [weak self] in
            guard let self = self, let fav = self.items.first(where: { $0.id == id }) else { return }
            self.copy(fav)   // hotkey copies the favorite to the clipboard
        }
    }

    // MARK: - Actions

    func copy(_ f: Favorite) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = f.text { pb.setString(t, forType: .string) }
        else if let p = f.file { pb.writeObjects([URL(fileURLWithPath: p) as NSURL]) }
        ClipboardHistory.shared.suppress()
    }

    func send(_ f: Favorite) {
        if let t = f.text {
            let dest = Uploader.shared.outbox.appendingPathComponent("fav-\(Uploader.stamp()).txt")
            try? t.write(to: dest, atomically: true, encoding: .utf8)
            Uploader.shared.enqueue([dest])
        } else if let p = f.file {
            Uploader.shared.enqueue([URL(fileURLWithPath: p)])
        }
    }

    private func shortLabel(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return String(t.prefix(40))
    }
}
