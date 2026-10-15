import AppKit

@MainActor
final class MeterContainer: NSView {
    private let scroll = NSScrollView()
    private let summaryScroll = NSScrollView()
    private let summary = AudioSummaryView()
    private let dragBar = SummaryDragBar()
    private let meters: MeterView
    private var automaticHorizontal: Bool?

    init(meters: MeterView) {
        self.meters = meters
        super.init(frame: .zero)
        summary.meters = meters
        meters.headerChanged = { [weak summary] in summary?.needsDisplay = true }
        for view in [scroll, summaryScroll] {
            view.drawsBackground = false
            view.contentView.drawsBackground = false
            view.automaticallyAdjustsContentInsets = false
            view.scrollerStyle = .overlay
            view.hasVerticalScroller = true
            addSubview(view)
        }
        scroll.hasHorizontalScroller = true
        scroll.documentView = meters
        summaryScroll.documentView = summary
        addSubview(dragBar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let count = meters.displayMeters.count
        let sidebarWidth = count == 0 ? bounds.width : (bounds.width < 480 ? CGFloat(144) : CGFloat(184))
        dragBar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: 28)
        summaryScroll.frame = NSRect(x: 0, y: 28, width: sidebarWidth, height: max(0, bounds.height - 28))
        summary.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: max(bounds.height - 28, meters.visibleMeters.contains(5) ? 200 : 72))
        scroll.frame = NSRect(x: sidebarWidth, y: 0, width: max(0, bounds.width - sidebarWidth), height: bounds.height)
        scroll.isHidden = count == 0
        guard count > 0 else { meters.spectrogramView.isHidden = true; return }
        let viewport = scroll.contentSize
        let horizontal: Bool
        if meters.arrangement == 1 { horizontal = true }
        else if meters.arrangement == 2 { horizontal = false }
        else {
            let ratio = viewport.width / max(1, viewport.height)
            if automaticHorizontal == nil { automaticHorizontal = ratio >= 1 }
            else if ratio >= 1.1 { automaticHorizontal = true }
            else if ratio <= 0.9 { automaticHorizontal = false }
            horizontal = automaticHorizontal == true
        }
        let columns = horizontal ? count : 1
        if meters.layoutColumns != columns || meters.layoutHorizontal != horizontal {
            meters.cancelInteraction()
            scroll.contentView.scroll(to: .zero)
        }
        meters.layoutColumns = columns
        meters.layoutHorizontal = horizontal
        let rows = (count + columns - 1) / columns
        meters.setFrameSize(NSSize(width: max(viewport.width, CGFloat(columns) * 150 + CGFloat(columns - 1) * 8 + 16),
            height: max(viewport.height, CGFloat(rows) * 110 + CGFloat(rows - 1) * 8 + (horizontal ? 6 : 14))))
        scroll.reflectScrolledClipView(scroll.contentView)
        meters.needsDisplay = true
        summary.needsDisplay = true
    }
}

@MainActor
private final class AudioSummaryView: NSView {
    weak var meters: MeterView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let meters else { return }
        let parts = meters.sourceLabel.components(separatedBy: " · ")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, line) in parts.enumerated() {
            (line as NSString).draw(in: NSRect(x: 12, y: 7 + CGFloat(index) * 14, width: bounds.width - 24, height: 14),
                withAttributes: [.font: (NSFont(name: "Menlo", size: 9) ?? NSFont.systemFont(ofSize: 9)),
                                 .foregroundColor: NSColor.white.withAlphaComponent(index == 0 ? 0.8 : 0.45),
                                 .paragraphStyle: paragraph])
        }
        if meters.visibleMeters.contains(5) {
            ("LOUDNESS" as NSString).draw(at: NSPoint(x: 12, y: 59), withAttributes: [
                .font: (NSFont(name: "Menlo", size: 9) ?? NSFont.systemFont(ofSize: 9)),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55)])
            meters.loudness(in: NSRect(x: 10, y: 80, width: min(180, bounds.width - 24), height: max(110, bounds.height - 92)))
        }
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 1, y: 7))
        separator.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxY - 7))
        separator.stroke()
    }
}

@MainActor
private final class SummaryDragBar: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
