import Cocoa
import CoreGraphics
import ApplicationServices

/// Owns the floating non-activating panel, its placement *in* the notch, the
/// reveal/hide spring, and the hover-to-paste event tap.
///
/// Hover is detected by polling the cursor against two zones with hysteresis —
/// a small zone at the notch opens it, and it only closes once the cursor leaves
/// a much larger zone. The window never drives hover via its own (resizing)
/// tracking area, which is what caused the open/close vibration.
final class NotchController: NSObject {
    let panel: NSPanel
    let view: NotchView

    private(set) var revealed = false
    var draggingOut = false {        // a file is being dragged out of the strip
        didSet { view.setTrashVisible(draggingOut) }   // reveal the trash corner during a drag
    }
    private var hoverTimer: Timer?
    private var holdUntil = Date.distantPast     // keep open briefly after a drop (show ✓)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityPoll: Timer?

    private let overhang: CGFloat = 22            // card extends above the screen top so its
                                                  // top corners are off-screen (clean square top)
    private let headerH: CGFloat = 48             // status row (must match NotchView)
    private let sidePad: CGFloat = 16
    private var mirrorRoot: URL { URL(fileURLWithPath: Config.mirrorPath) }
    private lazy var currentDir: URL = mirrorRoot // Finder-like browse location; reset to root on reveal
    var atRoot: Bool { currentDir.standardizedFileURL.path == mirrorRoot.standardizedFileURL.path }

    override init() {
        view = NotchView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        panel = NSPanel(contentRect: view.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        view.autoresizingMask = [.width, .height]
        view.layerContentsRedrawPolicy = .duringViewResize
        view.controller = self
        view.fileGrid.controller = self
        view.trashZone.controller = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show() {
        view.contentTopInset = contentTopInset()
        panel.setFrame(frame(revealed: false), display: true)
        panel.orderFrontRegardless()
        armPasteTap()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: true) { [weak self] _ in
            self?.hoverTick()
        }
        hoverTimer?.tolerance = 0.02
    }

    func refresh() { view.needsDisplay = true }

    // MARK: - Directory browsing

    func reloadDir() {
        if !currentDir.standardizedFileURL.path.hasPrefix(mirrorRoot.standardizedFileURL.path) { currentDir = mirrorRoot }
        let all = DirListing.contents(of: currentDir)
        let cap = 80
        let entries = Array(all.prefix(cap))
        let crumb = breadcrumb() + (all.count > cap ? "  (\(cap) of \(all.count))" : "")
        view.setBrowser(entries: entries, breadcrumb: crumb, atRoot: atRoot)
    }
    func navigate(into dir: URL) { currentDir = dir; reloadDir() }
    func navigateUp() { guard !atRoot else { return }; currentDir = currentDir.deletingLastPathComponent(); reloadDir() }

    private func breadcrumb() -> String {
        let root = mirrorRoot.standardizedFileURL.path
        let cur = currentDir.standardizedFileURL.path
        guard cur != root, cur.hasPrefix(root + "/") else { return mirrorRoot.lastPathComponent }
        let rel = String(cur.dropFirst(root.count + 1)).replacingOccurrences(of: "/", with: " › ")
        return mirrorRoot.lastPathComponent + " › " + rel
    }

    // MARK: - Geometry

    private func notchScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// (top edge y, horizontal centre, notch width, notch height).
    private func geo() -> (top: CGFloat, midX: CGFloat, notchW: CGFloat, inset: CGFloat)? {
        guard let s = notchScreen() else { return nil }
        let inset = s.safeAreaInsets.top
        var notchW: CGFloat = 200
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notchW = max(150, s.frame.width - l.width - r.width)
        }
        return (s.frame.maxY, s.frame.midX, notchW, inset)
    }

    /// Distance from the panel's top edge down to the notch's bottom (overhang +
    /// notch height) — everything above this is behind/around the notch.
    private func contentTopInset() -> CGFloat {
        overhang + (geo()?.inset ?? 0)
    }

    private var cardWidth: CGFloat {
        CGFloat(FileGridView.columns) * FileGridView.tileW
            + CGFloat(FileGridView.columns - 1) * FileGridView.colGap + 2 * sidePad
    }
    private var cardBodyHeight: CGFloat {   // fixed 4-row viewport; larger folders scroll
        headerH + 8 + 4 * FileGridView.tileH + 3 * FileGridView.rowGap + 14
    }

    /// Both frames share a fixed top (`f.maxY + overhang`) and only grow downward,
    /// so the card unfurls out of the notch.
    private func frame(revealed reveal: Bool) -> NSRect {
        guard let g = geo() else { return NSRect(x: 600, y: 760, width: 360, height: 40) }
        let top = g.top + overhang
        if reveal {
            let h = overhang + g.inset + cardBodyHeight
            return NSRect(x: g.midX - cardWidth / 2, y: top - h, width: cardWidth, height: h)
        }
        let h = overhang + max(g.inset, 12)          // invisible strip covering the notch (catches drags)
        return NSRect(x: g.midX - g.notchW / 2, y: top - h, width: g.notchW, height: h)
    }

    // MARK: - Hover zones (hysteresis kills the vibration)

    /// Exactly the notch — the card opens only when the cursor is actually in it,
    /// not on approach. (Bounds come from safeAreaInsets + the auxiliary ears.)
    private func revealZone() -> NSRect {
        guard let g = geo() else { return .zero }
        let h = max(g.inset, 6)
        return NSRect(x: g.midX - g.notchW / 2, y: g.top - h, width: g.notchW, height: h)
    }

    /// Large: the card only closes once the cursor leaves this. Strictly contains
    /// revealZone, so there's a dead-band between opening and closing.
    private func hideZone() -> NSRect { frame(revealed: true).insetBy(dx: -26, dy: -26) }

    private func hoverTick() {
        guard geo() != nil else { return }
        let p = NSEvent.mouseLocation
        if revealed {
            if view.dragActive || draggingOut || Date() < holdUntil { return }
            if !hideZone().contains(p) { setExpanded(false) }
        } else if revealZone().contains(p) {
            setExpanded(true)
        }
    }

    // MARK: - Reveal / hide spring

    func setExpanded(_ reveal: Bool) {
        guard reveal != revealed else { return }
        revealed = reveal
        panel.hasShadow = reveal
        view.contentTopInset = contentTopInset()

        if reveal {
            currentDir = mirrorRoot     // always open at the mirror root
            view.showBrowser(true)
        } else {
            view.showBrowser(false)
        }

        let timing = reveal
            ? CAMediaTimingFunction(controlPoints: 0.34, 1.30, 0.60, 1.0)   // gentle overshoot down
            : CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.70, 0.30)   // clean ease-in up
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reveal ? 0.34 : 0.22
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame(revealed: reveal), display: true)
        }
        view.needsDisplay = true

        // Populate after the unfurl begins so building tiles never blocks the animation.
        if reveal { DispatchQueue.main.async { [weak self] in self?.reloadDir() } }
    }

    /// Keep the card up briefly after a drop so the ✓ is visible.
    func holdRevealed(_ seconds: TimeInterval) {
        holdUntil = Date().addingTimeInterval(seconds)
        setExpanded(true)
    }

    @objc private func screensChanged() {
        view.contentTopInset = contentTopInset()
        panel.setFrame(frame(revealed: revealed), display: true)
    }

    // MARK: - Hover-to-paste (⌘V), consumed so the focused app doesn't double-paste

    private func armPasteTap() {
        if AXIsProcessTrusted() { installPasteTap(); return }
        accessibilityPoll?.invalidate()
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate(); self?.installPasteTap(); self?.refresh()
        }
    }

    private func installPasteTap() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<NotchController>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handleTap(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, revealed,   // only when the card is open (i.e. hovering the notch)
              event.flags.contains(.maskCommand),
              event.getIntegerValueField(.keyboardEventKeycode) == 9 /* kVK_ANSI_V */ else {
            return Unmanaged.passUnretained(event)
        }
        guard Uploader.shared.clipboardHasSendable(NSPasteboard.general) else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            Uploader.shared.enqueuePasteboard(NSPasteboard.general)
        }
        return nil
    }
}
