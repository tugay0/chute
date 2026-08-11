import AppKit
import Carbon.HIToolbox

/// Minimal system-wide hotkey registration via Carbon (`RegisterEventHotKey`).
/// No Accessibility permission needed. Supports one re-registerable "capture"
/// hotkey (for the remap in Preferences).
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    private var captureRef: EventHotKeyRef?
    private var captureAction: (() -> Void)?
    private var lastCode: UInt32 = 0
    private var lastMods: UInt32 = 0
    private let captureID: UInt32 = 1000

    func setCaptureHotKey(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        captureAction = action
        _ = updateCaptureHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    /// Re-point the capture hotkey to a new combo (keeps the same action).
    /// Returns false if the combo couldn't be registered (e.g. already owned by
    /// the system); in that case the previous combo is restored.
    @discardableResult
    func updateCaptureHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        installHandlerIfNeeded()
        if comboInUse(keyCode, modifiers, excluding: captureID) { return false }   // taken by a favorite
        if let r = captureRef { UnregisterEventHotKey(r); captureRef = nil }
        guard let action = captureAction else { return false }
        actions[captureID] = action
        let hkID = EventHotKeyID(signature: 0x43485554 /* 'CHUT' */, id: captureID)

        var ref: EventHotKeyRef?
        if RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref = ref {
            captureRef = ref; lastCode = keyCode; lastMods = modifiers
            combos[captureID] = (keyCode, modifiers)
            return true
        }
        // Registration failed — roll back to the previous working combo.
        if lastCode != 0 {
            var back: EventHotKeyRef?
            if RegisterEventHotKey(lastCode, lastMods, hkID, GetApplicationEventTarget(), 0, &back) == noErr {
                captureRef = back
                combos[captureID] = (lastCode, lastMods)
            }
        }
        return false
    }

    // MARK: - Favorite hotkeys (many, keyed by favorite id)

    private var favRefs: [String: EventHotKeyRef] = [:]
    private var favNums: [String: UInt32] = [:]
    private var combos: [UInt32: (UInt32, UInt32)] = [:]   // hotkey num -> (keyCode, mods)
    private var nextFavNum: UInt32 = 2000

    /// Is this combo already bound by a *different* owner (favorite or capture)?
    /// RegisterEventHotKey doesn't reliably reject in-process duplicates, so we
    /// dedupe ourselves.
    private func comboInUse(_ keyCode: UInt32, _ mods: UInt32, excluding num: UInt32) -> Bool {
        for (n, c) in combos where n != num && c.0 == keyCode && c.1 == mods { return true }
        return false
    }

    @discardableResult
    func registerFavorite(id: String, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let num = favNums[id] ?? { let n = nextFavNum; nextFavNum += 1; favNums[id] = n; return n }()
        if comboInUse(keyCode, modifiers, excluding: num) { return false }   // taken by another

        // Register the NEW combo before tearing down the old, so a failure leaves
        // the favorite's existing hotkey working.
        var newRef: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: 0x43485554, id: num)
        guard RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &newRef) == noErr,
              let newRef = newRef else { return false }
        if let old = favRefs[id] { UnregisterEventHotKey(old) }
        favRefs[id] = newRef
        combos[num] = (keyCode, modifiers)
        actions[num] = action
        return true
    }

    func unregisterFavorite(id: String) {
        if let r = favRefs[id] { UnregisterEventHotKey(r); favRefs[id] = nil }
        if let num = favNums[id] { actions[num] = nil; combos[num] = nil; favNums[id] = nil }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let action = HotKeyManager.shared.actions[hkID.id] {
                DispatchQueue.main.async { action() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    // MARK: - Modifier / label helpers (used by the recorder)

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static func label(_ event: NSEvent) -> String {
        var s = ""
        if event.modifierFlags.contains(.control) { s += "⌃" }
        if event.modifierFlags.contains(.option)  { s += "⌥" }
        if event.modifierFlags.contains(.shift)   { s += "⇧" }
        if event.modifierFlags.contains(.command) { s += "⌘" }
        s += (event.charactersIgnoringModifiers ?? "").uppercased()
        return s
    }
}
