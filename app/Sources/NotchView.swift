import Cocoa
import ApplicationServices

/// The drawn card + a Finder-like directory browser. The top `contentTopInset`
/// points sit behind/around the notch; a header (status + breadcrumb + back) and
/// a scrollable file grid are drawn below. Hover is driven by cursor polling.
final class NotchView: NSView {
    weak var controller: NotchController?
    var dragActive = false
    var contentTopInset: CGFloat = 0
    private let headerH: CGFloat = 48

    let fileGrid = FileGridView(frame: .zero)     // the scroll view's document
    let trashZone = TrashZone(frame: .zero)       // drag-to-delete corner
    private let scroll = NSScrollView(frame: .zero)

    private var breadcrumb = "Chute"
    private var atRoot = true

    private let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("com.adobe.pdf")
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL] + imageTypes)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = fileGrid
        scroll.contentView.drawsBackground = false
        scroll.isHidden = true
        addSubview(scroll)

        trashZone.isHidden = true
        addSubview(trashZone)
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Browser API (called by the controller)

    func setBrowser(entries: [(url: URL, isDir: Bool)], breadcrumb: String, atRoot: Bool) {
        self.breadcrumb = breadcrumb
        self.atRoot = atRoot
        fileGrid.setEntries(entries)
        sizeDocument()
        scroll.contentView.scroll(to: .zero)          // back to top (flipped doc)
        scroll.reflectScrolledClipView(scroll.contentView)
        needsDisplay = true
    }

    func showBrowser(_ show: Bool) { scroll.isHidden = !show }
    func setTrashVisible(_ visible: Bool) { trashZone.isHidden = !visible; if visible { trashZone.needsDisplay = true } }

    private func sizeDocument() {
        // Fixed final content width (5 columns), so tiles lay out at their final
        // 108px width immediately instead of compressing while the card unfurls.
        let w = CGFloat(FileGridView.columns) * FileGridView.tileW + CGFloat(FileGridView.columns - 1) * FileGridView.colGap
        fileGrid.frame = NSRect(x: 0, y: 0, width: w, height: max(scroll.contentSize.height, fileGrid.contentHeight()))
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let bodyTop = bounds.maxY - contentTopInset
        let gridTop = bodyTop - headerH - 8
        let gridBottom: CGFloat = 14
        scroll.frame = NSRect(x: 16, y: gridBottom, width: max(0, bounds.width - 32), height: max(0, gridTop - gridBottom))
        sizeDocument()
        let ts: CGFloat = 40
        trashZone.frame = NSRect(x: bounds.width - ts - 14, y: bodyTop - ts - 4, width: ts, height: ts)
    }

    private var isRevealed: Bool { controller?.revealed == true }

    private func backButtonRect() -> NSRect {
        let bodyTop = bounds.maxY - contentTopInset
        return NSRect(x: 26, y: bodyTop - 34, width: 24, height: 24)
    }

    override func mouseDown(with event: NSEvent) {
        guard isRevealed else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !atRoot && backButtonRect().contains(p) { controller?.navigateUp() }
    }

    // MARK: - Drawing (height-driven)

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        if bounds.height <= max(contentTopInset, 10) + 6 {
            drawResting(r)
        } else {
            drawCard(r, showText: bounds.height > contentTopInset + 44)
        }
    }

    private func drawResting(_ r: NSRect) {
        let state = Status.shared.state
        guard state == .sending || state == .error else { return }
        let w = r.width * 0.55
        let sliver = NSRect(x: r.midX - w / 2, y: r.minY + 1, width: w, height: 3)
        Status.shared.color.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: sliver, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func drawCard(_ r: NSRect, showText: Bool) {
        let card = r.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: card, xRadius: 20, yRadius: 20)
        NSColor(white: 0.04, alpha: 0.97).setFill(); path.fill()
        NSColor(white: 1, alpha: dragActive ? 0.95 : 0.13).setStroke()
        path.lineWidth = dragActive ? 2 : 1
        path.stroke()

        let bodyTop = r.maxY - contentTopInset

        // Status dot (top-left).
        Status.shared.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + 14, y: bodyTop - 22, width: 7, height: 7)).fill()

        guard showText else { return }

        // Back chevron (when not at root).
        var textX = r.minX + 30
        if !atRoot {
            drawText("‹", at: NSPoint(x: r.minX + 28, y: bodyTop - 34),
                     size: 20, weight: .medium, color: NSColor(white: 1, alpha: 0.85))
            textX = r.minX + 50
        }

        // Breadcrumb (truncates the head so the current folder stays visible).
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingHead
        let bcW = max(0, r.maxX - textX - 60)
        (breadcrumb as NSString).draw(in: NSRect(x: textX, y: bodyTop - 32, width: bcW, height: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: NSColor.white, .paragraphStyle: ps])

        if fileGrid.isEmpty {
            drawText("Empty folder", at: NSPoint(x: r.minX + 22, y: (bodyTop - 40) / 2),
                     size: 11, weight: .regular, color: NSColor(white: 1, alpha: 0.34))
        }
    }

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
        ])
    }

    // MARK: - Drag & drop (incoming files to send)

    private func canAccept(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if NSImage(pasteboard: pb) != nil { return true }
        return pb.availableType(from: imageTypes) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if controller?.draggingOut == true { return [] }   // internal drag → only the trash corner accepts
        guard canAccept(sender.draggingPasteboard) else { return [] }
        dragActive = true
        controller?.setExpanded(true)
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragActive = false; needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragActive = false; needsDisplay = true
        controller?.holdRevealed(0.9)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { canAccept(sender.draggingPasteboard) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragActive = false; needsDisplay = true
        return Uploader.shared.enqueuePasteboard(sender.draggingPasteboard)
    }
}
