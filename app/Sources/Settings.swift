import Foundation

/// A send target: a name + SSH host + remote folder.
struct Destination: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var host: String
    var folder: String
}

/// UserDefaults-backed configuration. The SwiftUI prefs view binds to the same
/// keys via @AppStorage; non-UI code reads through these accessors.
/// (Named `Config`, not `Settings`, to avoid colliding with SwiftUI.Settings.)
enum Config {
    static let d = UserDefaults.standard

    static let kHost         = "chute.remoteHost"   // legacy single host (migrated into destinations)
    static let kFolder       = "chute.remoteFolder"
    static let kCopyFormat   = "chute.copyFormat"
    static let kSound        = "chute.soundOnSend"
    static let kHotkeyCode   = "chute.hotkeyKeyCode"
    static let kHotkeyMods   = "chute.hotkeyModifiers"
    static let kHotkeyLabel  = "chute.hotkeyLabel"
    static let kSyncEnabled  = "chute.syncEnabled"
    static let kMirrorPath   = "chute.mirrorPath"
    static let kDestinations = "chute.destinations"
    static let kActiveDest   = "chute.activeDest"
    static let kSortMode     = "chute.sortMode"     // "name" | "date" | "size"
    static let kListView     = "chute.listView"

    static func registerDefaults() {
        d.register(defaults: [
            kCopyFormat: "~/{folder}{name}",
            kSound: true,
            kHotkeyCode: 21,        // kVK_ANSI_4
            kHotkeyMods: 0x900,     // Carbon cmdKey(0x100) | optionKey(0x800)
            kHotkeyLabel: "⌥⌘4",
            kSyncEnabled: true,
            kMirrorPath: NSHomeDirectory() + "/Chute",
            kSortMode: "name",
            kListView: false,
        ])
    }

    // MARK: - Destinations

    static func destinations() -> [Destination] {
        if let data = d.data(forKey: kDestinations),
           let ds = try? JSONDecoder().decode([Destination].self, from: data), !ds.isEmpty { return ds }
        // migrate from the legacy single host/folder (or a stock default)
        let h = (d.string(forKey: kHost) ?? "remote-box")
        let f = (d.string(forKey: kFolder) ?? "inbox/")
        return [Destination(name: "Inbox", host: h.isEmpty ? "remote-box" : h, folder: f.isEmpty ? "inbox/" : f)]
    }
    static func setDestinations(_ ds: [Destination]) {
        if let data = try? JSONEncoder().encode(ds) { d.set(data, forKey: kDestinations) }
    }
    // Active destination tracked by ID so it survives reorder/remove (an index
    // would silently point at a different destination after an edit).
    static var activeDestID: String {
        get { d.string(forKey: kActiveDest) ?? "" }
        set { d.set(newValue, forKey: kActiveDest) }
    }
    static func setActive(id: String) { activeDestID = id }
    static var activeDest: Destination {
        let ds = destinations()
        return ds.first(where: { $0.id == activeDestID }) ?? ds.first ?? Destination(name: "Inbox", host: "remote-box", folder: "inbox/")
    }
    static var activeIndex: Int { destinations().firstIndex(where: { $0.id == activeDestID }) ?? 0 }

    // The mirror / browser use a FIXED config (kHost/kFolder), independent of the
    // send-destinations list — so editing destinations never re-points the mirror.
    static var host: String   { normHost(d.string(forKey: kHost) ?? "remote-box") }
    static var folder: String { normFolder(d.string(forKey: kFolder) ?? "inbox/") }
    static var sendHost: String   { normHost(activeDest.host) }
    static var sendFolder: String { normFolder(activeDest.folder) }
    static var isDefaultSend: Bool { sendHost == "remote-box" && sendFolder == "inbox/" }

    private static func normHost(_ raw: String) -> String {
        let h = raw.trimmingCharacters(in: .whitespaces); return h.isEmpty ? "remote-box" : h
    }
    private static func normFolder(_ raw: String) -> String {
        var f = raw.trimmingCharacters(in: .whitespaces)
        if f.isEmpty { f = "inbox/" }
        if !f.hasSuffix("/") { f += "/" }        // always a directory, never overwrite a file
        return f
    }

    // MARK: - Other

    static var copyFormat: String {
        let v = d.string(forKey: kCopyFormat) ?? "~/{folder}{name}"
        return v == "~/inbox/{name}" ? "~/{folder}{name}" : v   // migrate the old inbox-hardcoded default
    }
    static var soundOnSend: Bool   { d.bool(forKey: kSound) }
    static var hotkeyCode: UInt32  { UInt32(d.integer(forKey: kHotkeyCode)) }
    static var hotkeyMods: UInt32  { UInt32(d.integer(forKey: kHotkeyMods)) }
    static var hotkeyLabel: String { d.string(forKey: kHotkeyLabel) ?? "⌥⌘4" }
    static var syncEnabled: Bool   { d.bool(forKey: kSyncEnabled) }
    static var mirrorPath: String {
        let p = (d.string(forKey: kMirrorPath) ?? "").trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? NSHomeDirectory() + "/Chute" : p
    }
    static var sortMode: String { d.string(forKey: kSortMode) ?? "name" }
    static var listView: Bool   { d.bool(forKey: kListView) }
}
