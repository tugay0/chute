import AppKit
import SwiftUI
import ServiceManagement

/// Shows the SwiftUI preferences window. Flips to a regular (dock-visible) app
/// while open so the window can take focus, then back to accessory on close.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Chute Preferences"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Editable list of send destinations, persisted to Config on every change.
final class DestinationsStore: ObservableObject {
    static let shared = DestinationsStore()
    @Published var items: [Destination] { didSet { Config.setDestinations(items) } }
    private init() { items = Config.destinations() }

    func add() { items.append(Destination(name: "Destination \(items.count + 1)", host: "remote-box", folder: "inbox/")) }
    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        if items.isEmpty { items = [Destination(name: "Inbox", host: "remote-box", folder: "inbox/")] }
    }
}

struct SettingsView: View {
    @ObservedObject private var dests = DestinationsStore.shared
    @AppStorage(Config.kCopyFormat) private var copyFormat = "~/inbox/{name}"
    @AppStorage(Config.kSound)      private var sound = true
    @AppStorage(Config.kHotkeyLabel) private var hotkeyLabel = "⌥⌘4"
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @AppStorage(Config.kSyncEnabled) private var syncEnabled = true
    @AppStorage(Config.kMirrorPath)  private var mirrorPath = NSHomeDirectory() + "/Chute"
    @ObservedObject private var favorites = Favorites.shared

    var body: some View {
        Form {
            Section("Destinations (where sends go — switch via menu bar → Send to)") {
                ForEach($dests.items) { $d in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            TextField("Name", text: $d.name)
                            Button { dests.remove(d.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Remove destination")
                        }
                        HStack {
                            TextField("host", text: $d.host).font(.system(.caption, design: .monospaced))
                            Text(":").foregroundStyle(.secondary)
                            TextField("folder", text: $d.folder).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Button("Add destination") { dests.add() }
                Text("Sends route to the active destination (menu bar → Send to). The ~/Chute mirror is separate — see below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On send") {
                TextField("Copy format", text: $copyFormat)
                Text("Copied to the clipboard after each send. {name} = filename.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play a sound", isOn: $sound)
            }
            Section("Capture hotkey") {
                HStack {
                    Text("Shortcut").foregroundStyle(.secondary)
                    Spacer()
                    Text(hotkeyLabel).font(.system(.body, design: .monospaced))
                    HotkeyRecorder { code, mods, label in
                        if HotKeyManager.shared.updateCaptureHotKey(keyCode: code, modifiers: mods) {
                            Config.d.set(Int(code), forKey: Config.kHotkeyCode)
                            Config.d.set(Int(mods), forKey: Config.kHotkeyMods)
                            Config.d.set(label, forKey: Config.kHotkeyLabel)
                            return true
                        }
                        return false
                    }
                }
            }
            Section("Favorites") {
                if favorites.items.isEmpty {
                    Text("Pin items from Clipboard history (⌃-click) to add favorites, then give them a hotkey here.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(favorites.items) { fav in
                        HStack(spacing: 8) {
                            Text(fav.label).lineLimit(1)
                            Spacer()
                            if let hl = fav.hotkeyLabel {
                                Text(hl).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                Button { Favorites.shared.clearHotkey(id: fav.id) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless).help("Clear hotkey")
                            }
                            HotkeyRecorder { code, mods, label in
                                Favorites.shared.setHotkey(id: fav.id, keyCode: code, mods: mods, label: label)
                            }
                            Button { Favorites.shared.remove(fav.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Remove favorite")
                        }
                    }
                }
            }
            Section("Local folder sync (2-way mirror)") {
                Toggle("Sync ~/Chute ↔ \(Config.host):\(Config.folder)", isOn: Binding(
                    get: { syncEnabled },
                    set: { on in syncEnabled = on; FolderSync.shared.reload() }))
                TextField("Local folder", text: $mirrorPath)
                HStack {
                    Text(FolderSync.shared.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal in Finder") {
                        let url = URL(fileURLWithPath: mirrorPath, isDirectory: true)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("Files sync both ways. Deletes go to the Trash (local) / .chute-trash on the server — recoverable, never hard-deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        launchAtLogin = on
                        do { if on { try SMAppService.mainApp.register() }
                             else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
                    }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }
}

/// A tiny "Record…" button that captures the next key combo. `onCapture` returns
/// true if the combo was accepted (registered); false makes it beep and keep
/// listening. Torn down if the view leaves the window mid-record.
struct HotkeyRecorder: NSViewRepresentable {
    var onCapture: (UInt32, UInt32, String) -> Bool
    func makeNSView(context: Context) -> RecorderButton { RecorderButton(onCapture: onCapture) }
    func updateNSView(_ nsView: RecorderButton, context: Context) {}
}

final class RecorderButton: NSButton {
    private let onCapture: (UInt32, UInt32, String) -> Bool
    private var monitor: Any?

    init(onCapture: @escaping (UInt32, UInt32, String) -> Bool) {
        self.onCapture = onCapture
        super.init(frame: .zero)
        title = "Record…"
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { finish() }
    }

    @objc private func begin() {
        guard monitor == nil else { return }
        title = "Press keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            if e.keyCode == 53 { self.finish(); return nil }          // Escape cancels
            let mods = HotKeyManager.carbonModifiers(e.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }        // require a modifier
            if self.onCapture(UInt32(e.keyCode), mods, HotKeyManager.label(e)) { self.finish() }
            else { NSSound.beep() }                                    // taken/rejected; keep listening
            return nil
        }
    }

    private func finish() {
        title = "Record…"
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
