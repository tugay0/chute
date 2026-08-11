import AppKit

/// Keeps the last N clipboard items so they can be re-copied or sent to the box.
/// Favorites + per-item hotkeys build on top of this (next stage).
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    struct Item {
        enum Kind { case text(String); case file(URL); case image(URL) }
        let kind: Kind
        let label: String
    }

    private(set) var items: [Item] = []
    private let maxItems = 10
    private let dir: URL
    private var lastChange: Int
    private var timer: Timer?

    private init() {
        dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Chute/history",
                  isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lastChange = NSPasteboard.general.changeCount
        // History is in-memory only, so every saved image from a prior session is
        // now an orphan — purge them at launch.
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.2
    }

    /// Call after we set the clipboard ourselves so our own writes aren't captured.
    func suppress() { lastChange = NSPasteboard.general.changeCount }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        capture(pb)
    }

    private func capture(_ pb: NSPasteboard) {
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first {
            add(Item(kind: .file(u), label: "📄  " + u.lastPathComponent)); return
        }
        for (type, ext) in [("public.png", "png"), ("public.jpeg", "jpg"),
                            ("com.adobe.pdf", "pdf"), ("public.tiff", "tiff")] {
            if let data = pb.data(forType: NSPasteboard.PasteboardType(type)) {
                let dest = dir.appendingPathComponent("clip-\(Uploader.stamp()).\(ext)")
                try? data.write(to: dest)
                add(Item(kind: .image(dest), label: "🖼  Image (\(ext))")); return
            }
        }
        if let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let dest = dir.appendingPathComponent("clip-\(Uploader.stamp()).png")
            try? png.write(to: dest)
            add(Item(kind: .image(dest), label: "🖼  Image")); return
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let snippet = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            add(Item(kind: .text(s), label: String(snippet.prefix(48))))
        }
    }

    private func add(_ item: Item) {
        items.insert(item, at: 0)
        while items.count > maxItems {
            let removed = items.removeLast()
            if case let .image(u) = removed.kind { try? FileManager.default.removeItem(at: u) }
        }
    }

    // MARK: - Actions

    func copyToClipboard(_ item: Item) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s): pb.setString(s, forType: .string)
        case .file(let u), .image(let u): pb.writeObjects([u as NSURL])
        }
        suppress()   // don't re-capture what we just put back
    }

    func send(_ item: Item) {
        switch item.kind {
        case .text(let s):
            // Stage into the outbox so Uploader cleans it up after delivery.
            let dest = Uploader.shared.outbox.appendingPathComponent("text-\(Uploader.stamp()).txt")
            try? s.write(to: dest, atomically: true, encoding: .utf8)
            Uploader.shared.enqueue([dest])
        case .file(let u), .image(let u):
            Uploader.shared.enqueue([u])
        }
    }

    func clear() {
        for item in items { if case let .image(u) = item.kind { try? FileManager.default.removeItem(at: u) } }
        items.removeAll()
    }
}
