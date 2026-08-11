import Cocoa

/// The single source of truth for the sync indicator. Main-thread only.
enum SyncState { case idle, synced, sending, error, offline }

struct TransferItem { let name: String; let ok: Bool }

final class Status {
    static let shared = Status()

    private(set) var state: SyncState = .idle
    private(set) var pending: Int = 0
    private(set) var lastMessage: String = "Starting…"
    private(set) var recent: [TransferItem] = []

    /// Called on every change (main thread). The UI subscribes here.
    var onChange: (() -> Void)?

    func set(state: SyncState, pending: Int? = nil, message: String? = nil) {
        self.state = state
        if let p = pending { self.pending = max(0, p) }
        if let m = message { self.lastMessage = m }
        onChange?()
    }

    func pushRecent(_ item: TransferItem) {
        recent.insert(item, at: 0)
        if recent.count > 5 { recent.removeLast(recent.count - 5) }
    }

    // MARK: - Presentation

    var color: NSColor {
        switch state {
        case .idle:    return NSColor(white: 0.55, alpha: 1)
        case .synced:  return NSColor.systemGreen
        case .sending: return NSColor.systemOrange
        case .error:   return NSColor.systemRed
        case .offline: return NSColor(white: 0.45, alpha: 1)
        }
    }

    var headline: String {
        switch state {
        case .idle:    return "Connecting…"
        case .synced:  return "Synced"
        case .sending: return pending > 0 ? "Sending \(pending)…" : "Sending…"
        case .error:   return "Failed"
        case .offline: return "Server offline"
        }
    }

    var subline: String { lastMessage }

    /// Symbol used in the menu-bar button.
    var glyph: String {
        switch state {
        case .idle:    return "◌"
        case .synced:  return "●"
        case .sending: return "◐"
        case .error:   return "✕"
        case .offline: return "○"
        }
    }
}
