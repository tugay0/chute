import AppKit
import ImageIO

/// Contents of a directory — folders first, then files, each name-sorted
/// (case-insensitive), hidden entries skipped. Mirrors a Finder folder view.
enum DirListing {
    static func contents(of dir: URL) -> [(url: URL, isDir: Bool)] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let mode = Config.sortMode
        let entries = items.map { u -> (url: URL, isDir: Bool, date: Date, size: Int) in
            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            return (u, rv?.isDirectory ?? false, rv?.contentModificationDate ?? .distantPast, rv?.fileSize ?? 0)
        }
        return entries.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }   // folders always first
            switch mode {
            case "date": return a.date > b.date                    // newest first
            case "size": return a.size > b.size                    // largest first
            default:     return a.url.lastPathComponent.localizedCaseInsensitiveCompare(b.url.lastPathComponent) == .orderedAscending
            }
        }.map { ($0.url, $0.isDir) }
    }
}

/// A 5-column grid of directory entries (the scroll view's document view).
/// Flipped so it fills top-down and scrolls naturally.
final class FileGridView: NSView {
    static let columns = 5
    static let tileW: CGFloat = 108
    static let tileH: CGFloat = 92
    static let colGap: CGFloat = 12
    static let rowGap: CGFloat = 14

    static let listRowH: CGFloat = 40
    static let listGap: CGFloat = 4

    weak var controller: NotchController?
    private var tiles: [FileTile] = []
    private var listMode = false
    static var generation = 0     // bumped each navigation so stale async decodes can bail

    override var isFlipped: Bool { true }
    var isEmpty: Bool { tiles.isEmpty }

    func setEntries(_ entries: [(url: URL, isDir: Bool)]) {
        Self.generation &+= 1
        listMode = Config.listView
        tiles.forEach { $0.removeFromSuperview() }
        tiles = entries.map { e -> FileTile in
            let t = FileTile(url: e.url, isDir: e.isDir, rowMode: listMode); t.controller = controller; addSubview(t); return t
        }
        layoutTiles()
    }

    private var cols: Int { listMode ? 1 : Self.columns }
    private var rowH: CGFloat { listMode ? Self.listRowH : Self.tileH }
    private var rGap: CGFloat { listMode ? Self.listGap : Self.rowGap }

    func contentHeight() -> CGFloat {
        let rows = max(1, Int(ceil(Double(tiles.count) / Double(cols))))
        return CGFloat(rows) * rowH + CGFloat(rows - 1) * rGap
    }

    override func layout() { super.layout(); layoutTiles() }

    private func layoutTiles() {
        guard bounds.width > 0 else { return }
        let n = cols
        let tileW = n == 1 ? bounds.width : (bounds.width - Self.colGap * CGFloat(n - 1)) / CGFloat(n)
        for (i, t) in tiles.enumerated() {
            let col = i % n, row = i / n
            let x = n == 1 ? 0 : CGFloat(col) * (tileW + Self.colGap)
            t.frame = NSRect(x: x, y: CGFloat(row) * (rowH + rGap), width: tileW, height: rowH)
        }
    }
}

/// One entry: a folder (click → navigate in) or a file (click → open). Both drag
/// to export, or onto the red trash corner to delete. Whole tile is one target.
final class FileTile: NSView, NSDraggingSource {
    let url: URL
    let isDir: Bool
    let rowMode: Bool
    weak var controller: NotchController?
    private var image: NSImage
    private var isPreview: Bool
    private let label = NSTextField(labelWithString: "")
    private let thumbH: CGFloat = 58
    private let key: String       // cache key = path|mtime (invalidates when a file changes)
    private let gen: Int          // grid generation at creation (for stale-decode cancel)
    private var downAt: NSPoint = .zero
    private var dragging = false

    private static let thumbQueue = DispatchQueue(label: "com.github.tugay0.chute.thumbs", qos: .userInitiated)
    private static var cache: [String: NSImage] = [:]

    init(url: URL, isDir: Bool, rowMode: Bool) {
        self.url = url; self.isDir = isDir; self.rowMode = rowMode
        let k = FileTile.cacheKey(for: url)
        self.key = k
        self.gen = FileGridView.generation
        // Instant placeholder (system icon) — real image thumbnails load async so
        // navigating into a big folder never blocks the main thread.
        if let cached = FileTile.cache[k] {
            image = cached; isPreview = true
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path); isPreview = false
        }
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = url.lastPathComponent

        label.stringValue = url.lastPathComponent
        label.textColor = NSColor(white: 1, alpha: rowMode ? 0.92 : 0.78)
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false
        if rowMode {                                    // list row: full-width, single line, left
            label.font = .systemFont(ofSize: 12)
            label.alignment = .left
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
        } else {                                        // grid tile: 2 wrapped lines, centered
            label.font = .systemFont(ofSize: 9.5)
            label.alignment = .center
            label.usesSingleLineMode = false
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byCharWrapping
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = true
        }
        addSubview(label)

        if !isDir && !isPreview { loadThumbnailAsync() }
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    private func loadThumbnailAsync() {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "heif", "bmp", "webp"].contains(ext) else { return }
        let u = url, k = key, myGen = gen
        FileTile.thumbQueue.async {
            guard FileGridView.generation == myGen else { return }   // navigated away → skip the decode
            guard let img = FileTile.decode(u) else { return }
            DispatchQueue.main.async { [weak self] in
                FileTile.cache[k] = img
                if FileTile.cache.count > 500 { FileTile.cache.removeAll() }
                guard let self = self, self.url == u else { return }
                self.image = img; self.isPreview = true; self.needsDisplay = true
            }
        }
    }

    private static func cacheKey(for url: URL) -> String {
        let mt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(url.path)|\(mt)"
    }

    override func layout() {
        super.layout()
        if rowMode {
            let s: CGFloat = 28
            label.frame = NSRect(x: s + 14, y: (bounds.height - 18) / 2, width: max(0, bounds.width - s - 22), height: 18)
        } else {
            label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - thumbH - 4))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if rowMode {
            let s: CGFloat = 28
            let box = NSRect(x: 8, y: (bounds.height - s) / 2, width: s, height: s)
            if !isDir {
                let bg = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
                NSColor(white: 1, alpha: 0.06).setFill(); bg.fill()
                NSGraphicsContext.saveGraphicsState(); bg.addClip()
                drawImage(in: box, fill: isPreview)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                drawImage(in: box, fill: false)
            }
            return
        }
        let side = thumbH
        let box = NSRect(x: bounds.midX - side / 2, y: bounds.maxY - side, width: side, height: side)
        if !isDir {
            let bg = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
            NSColor(white: 1, alpha: 0.06).setFill(); bg.fill()
            NSGraphicsContext.saveGraphicsState(); bg.addClip()
            drawImage(in: box, fill: isPreview)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 1, alpha: 0.12).setStroke(); bg.lineWidth = 1; bg.stroke()
        } else {
            drawImage(in: box.insetBy(dx: 4, dy: 4), fill: false)   // folder icon, no chrome
        }
    }

    private func drawImage(in box: NSRect, fill: Bool) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = fill ? max(box.width / image.size.width, box.height / image.size.height)
                         : min(box.width / image.size.width, box.height / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        image.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
    }

    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow; dragging = false }
    override func mouseDragged(with e: NSEvent) {
        guard !dragging,
              abs(e.locationInWindow.x - downAt.x) > 4 || abs(e.locationInWindow.y - downAt.y) > 4 else { return }
        dragging = true
        controller?.draggingOut = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: bounds.midX - thumbH / 2, y: bounds.maxY - thumbH, width: thumbH, height: thumbH),
                              contents: image)
        beginDraggingSession(with: [item], event: e, source: self)
    }
    override func mouseUp(with e: NSEvent) {
        guard !dragging else { return }
        if isDir { controller?.navigate(into: url) } else { NSWorkspace.shared.open(url) }
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy.union(.delete) }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        controller?.draggingOut = false; dragging = false
    }

    // MARK: - Thumbnail decode (runs on the background thumb queue)

    private static func decode(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// A red corner that appears while dragging. Dropping trashes the file/folder
/// locally; FolderSync propagates the deletion to the server.
final class TrashZone: NSView {
    weak var controller: NotchController?
    private var active = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: box, xRadius: 11, yRadius: 11)
        NSColor.systemRed.withAlphaComponent(active ? 0.95 : 0.5).setFill(); path.fill()
        let glyph = "🗑" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: active ? 22 : 18)]
        let sz = glyph.size(withAttributes: attrs)
        glyph.draw(at: NSPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2 - 1), withAttributes: attrs)
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { active = true; needsDisplay = true; return .delete }
    override func draggingExited(_ s: NSDraggingInfo?) { active = false; needsDisplay = true }
    override func draggingEnded(_ s: NSDraggingInfo) { active = false; needsDisplay = true }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        active = false; needsDisplay = true
        guard let urls = s.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        FolderSync.shared.syncNow()
        controller?.reloadDir()
        return true
    }
}
