import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var notch: NotchController!
    var statusItem: NSStatusItem!
    private var historyMenu: NSMenu!
    private var favoritesMenu: NSMenu!
    private var sendToMenu: NSMenu!
    private var browserMenu: NSMenu!
    private var syncStatusItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.registerDefaults()
        requestAccessibilityIfNeeded()

        notch = NotchController()
        notch.show()
        setupStatusItem()

        Status.shared.onChange = { [weak self] in
            self?.notch.refresh()
            self?.updateStatusButton()
        }
        ClipboardHistory.shared.start()
        Uploader.shared.start()
        updateStatusButton()

        HotKeyManager.shared.setCaptureHotKey(keyCode: Config.hotkeyCode, modifiers: Config.hotkeyMods) {
            Uploader.shared.captureRegionAndSend()
        }
        Favorites.shared.registerAllHotkeys()
        FolderSync.shared.reload()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Menu-bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Chute — drop files to \(Config.host):~/\(Config.folder)"

        let menu = NSMenu()
        menu.delegate = self
        add(menu, "Capture region → send  (\(Config.hotkeyLabel))", #selector(captureRegion), key: "")
        add(menu, "Send clipboard now", #selector(sendClipboard), key: "v")

        sendToMenu = NSMenu(); sendToMenu.delegate = self
        menu.addItem(withTitle: "Send to", action: nil, keyEquivalent: "").submenu = sendToMenu

        historyMenu = NSMenu(); historyMenu.delegate = self
        menu.addItem(withTitle: "Clipboard history", action: nil, keyEquivalent: "").submenu = historyMenu

        favoritesMenu = NSMenu(); favoritesMenu.delegate = self
        menu.addItem(withTitle: "Favorites", action: nil, keyEquivalent: "").submenu = favoritesMenu

        menu.addItem(.separator())
        syncStatusItem = menu.addItem(withTitle: "Folder sync", action: nil, keyEquivalent: "")
        syncStatusItem.isEnabled = false
        add(menu, "Open Chute folder", #selector(openMirror), key: "")
        browserMenu = NSMenu(); browserMenu.delegate = self
        menu.addItem(withTitle: "Browser view", action: nil, keyEquivalent: "").submenu = browserMenu
        add(menu, "Sync now", #selector(syncNow), key: "")

        menu.addItem(.separator())
        add(menu, "Check server", #selector(reconnect), key: "r")
        add(menu, "Open outbox folder", #selector(openOutbox), key: "")
        add(menu, "Preferences…", #selector(openPrefs), key: ",")
        add(menu, "Quit Chute", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu { buildHistoryMenu(menu) }
        else if menu === favoritesMenu { buildFavoritesMenu(menu) }
        else if menu === sendToMenu { buildSendToMenu(menu) }
        else if menu === browserMenu { buildBrowserMenu(menu) }
        else if menu === statusItem.menu { syncStatusItem.title = FolderSync.shared.statusText }
    }

    /// Destinations (radio) — pick where sends go; the active one is checked.
    private func buildSendToMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let dests = Config.destinations()
        for (i, dst) in dests.enumerated() {
            let it = menu.addItem(withTitle: "\(dst.name)   \(dst.host):\(dst.folder)",
                                  action: #selector(pickDestination(_:)), keyEquivalent: "")
            it.target = self; it.tag = i
            it.state = (i == Config.activeIndex) ? .on : .off
        }
        menu.addItem(.separator())
        let manage = menu.addItem(withTitle: "Manage destinations…", action: #selector(openPrefs), keyEquivalent: "")
        manage.target = self
    }

    /// View (grid/list) + sort (name/date/size), both radio.
    private func buildBrowserMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let grid = menu.addItem(withTitle: "Grid", action: #selector(setGridView), keyEquivalent: "")
        grid.target = self; grid.state = Config.listView ? .off : .on
        let list = menu.addItem(withTitle: "List", action: #selector(setListView), keyEquivalent: "")
        list.target = self; list.state = Config.listView ? .on : .off
        menu.addItem(.separator())
        for (title, key) in [("Name", "name"), ("Date modified", "date"), ("Size", "size")] {
            let it = menu.addItem(withTitle: title, action: #selector(setSort(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = key
            it.state = (Config.sortMode == key) ? .on : .off
        }
    }

    /// Normal click copies back · ⌥-click sends · ⌃-click pins to favorites.
    private func buildHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = ClipboardHistory.shared.items
        if items.isEmpty {
            menu.addItem(withTitle: "No clipboard history yet", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for (i, item) in items.enumerated() {
            let copy = menu.addItem(withTitle: "📋  \(item.label)", action: #selector(copyHistory(_:)), keyEquivalent: "")
            copy.target = self; copy.tag = i
            let send = menu.addItem(withTitle: "⬆︎  Send: \(item.label)", action: #selector(sendHistory(_:)), keyEquivalent: "")
            send.target = self; send.tag = i; send.isAlternate = true; send.keyEquivalentModifierMask = .option
            let pin = menu.addItem(withTitle: "📌  Pin: \(item.label)", action: #selector(pinHistory(_:)), keyEquivalent: "")
            pin.target = self; pin.tag = i; pin.isAlternate = true; pin.keyEquivalentModifierMask = .control
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear history", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
    }

    /// Normal click copies · ⌥-click sends. Hotkey (if any) shown in the title.
    private func buildFavoritesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let favs = Favorites.shared.items
        if favs.isEmpty {
            menu.addItem(withTitle: "No favorites — ⌃-click a history item to pin", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for (i, f) in favs.enumerated() {
                let suffix = f.hotkeyLabel.map { "   \($0)" } ?? ""
                let copy = menu.addItem(withTitle: "📌  \(f.label)\(suffix)", action: #selector(copyFav(_:)), keyEquivalent: "")
                copy.target = self; copy.tag = i
                let send = menu.addItem(withTitle: "⬆︎  Send: \(f.label)", action: #selector(sendFav(_:)), keyEquivalent: "")
                send.target = self; send.tag = i; send.isAlternate = true; send.keyEquivalentModifierMask = .option
            }
        }
        menu.addItem(.separator())
        let manage = menu.addItem(withTitle: "Manage / assign hotkeys…", action: #selector(openPrefs), keyEquivalent: "")
        manage.target = self
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = NSAttributedString(string: Status.shared.glyph, attributes: [
            .foregroundColor: Status.shared.color,
            .font: NSFont.systemFont(ofSize: 15)
        ])
        button.toolTip = "Chute — \(Status.shared.headline) · \(Status.shared.subline)"
    }

    // MARK: - Actions

    @objc private func captureRegion() { Uploader.shared.captureRegionAndSend() }
    @objc private func sendClipboard() { Uploader.shared.enqueueClipboard() }
    @objc private func openOutbox()    { NSWorkspace.shared.open(Uploader.shared.outbox) }
    @objc private func reconnect()     { Uploader.shared.checkNow(manual: true) }
    @objc private func openMirror() {
        let url = URL(fileURLWithPath: Config.mirrorPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
    @objc private func syncNow()       { FolderSync.shared.syncNow() }
    @objc private func openPrefs()     { SettingsWindowController.shared.show() }

    @objc private func pickDestination(_ sender: NSMenuItem) {
        let ds = Config.destinations()
        guard sender.tag < ds.count else { return }
        Config.setActive(id: ds[sender.tag].id)   // by id, so remove/reorder can't mis-route
        Uploader.shared.checkNow(manual: true)     // re-check reachability of the new host
        updateStatusButton()
    }
    @objc private func setGridView() { Config.d.set(false, forKey: Config.kListView); notch.reloadDir() }
    @objc private func setListView() { Config.d.set(true, forKey: Config.kListView); notch.reloadDir() }
    @objc private func setSort(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { Config.d.set(key, forKey: Config.kSortMode); notch.reloadDir() }
    }
    @objc private func quit()          { NSApp.terminate(nil) }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        let items = ClipboardHistory.shared.items
        guard sender.tag < items.count else { return }
        ClipboardHistory.shared.copyToClipboard(items[sender.tag])
    }
    @objc private func sendHistory(_ sender: NSMenuItem) {
        let items = ClipboardHistory.shared.items
        guard sender.tag < items.count else { return }
        ClipboardHistory.shared.send(items[sender.tag])
    }
    @objc private func pinHistory(_ sender: NSMenuItem) {
        let items = ClipboardHistory.shared.items
        guard sender.tag < items.count else { return }
        Favorites.shared.pin(items[sender.tag])
    }
    @objc private func clearHistory() { ClipboardHistory.shared.clear() }

    @objc private func copyFav(_ sender: NSMenuItem) {
        let favs = Favorites.shared.items
        guard sender.tag < favs.count else { return }
        Favorites.shared.copy(favs[sender.tag])
    }
    @objc private func sendFav(_ sender: NSMenuItem) {
        let favs = Favorites.shared.items
        guard sender.tag < favs.count else { return }
        Favorites.shared.send(favs[sender.tag])
    }

    // MARK: - Permissions

    private func requestAccessibilityIfNeeded() {
        if AXIsProcessTrusted() { return }
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(options)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
