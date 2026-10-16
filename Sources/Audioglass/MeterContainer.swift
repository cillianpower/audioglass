import AppKit

@MainActor
final class MeterContainer: NSView {
    private let scroll = NSScrollView()
    private let summaryScroll = NSScrollView()
    private let summary = AudioSummaryView()
    private let dragBar = SummaryDragBar()
    private let meters: MeterView
    private var automaticHorizontal: Bool?
    /// Horizontal strips never scroll vertically; the sidebar clips instead.
    private var clipsSummary = false
    private var summaryHeight: CGFloat {
        summary.atTop ? summary.topHeight(width: bounds.width) : max(summaryScroll.frame.height, clipsSummary ? 0 : summary.contentHeight)
    }

    init(meters: MeterView) {
        self.meters = meters
        super.init(frame: .zero)
        summary.meters = meters
        meters.headerChanged = { [weak self] in
            guard let self else { return }
            summary.needsDisplay = true
            if summary.frame.height != summaryHeight { needsLayout = true }
        }
        for view in [scroll, summaryScroll] {
            view.drawsBackground = false
            view.contentView.drawsBackground = false
            view.automaticallyAdjustsContentInsets = false
            view.scrollerStyle = .overlay
            view.hasVerticalScroller = true
            // Without this, a scroller makes content bounce even when it already fits.
            view.verticalScrollElasticity = .none
            view.horizontalScrollElasticity = .none
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
        let sidebarWidth = count == 0 ? bounds.width : (bounds.width < 480 ? CGFloat(144) : CGFloat(160))
        let horizontal: Bool
        if count == 0 { horizontal = false }
        else if meters.arrangement == 1 { horizontal = true }
        else if meters.arrangement == 2 { horizontal = false }
        else {
            let ratio = (bounds.width - sidebarWidth) / max(1, bounds.height)
            if automaticHorizontal == nil { automaticHorizontal = ratio >= 1 }
            else if ratio >= 1.1 { automaticHorizontal = true }
            else if ratio <= 0.9 { automaticHorizontal = false }
            horizontal = automaticHorizontal == true
        }
        // Horizontal strips keep source and loudness in a left sidebar; vertical columns
        // move them to a block across the top, beside the traffic lights.
        summary.atTop = count > 0 && !horizontal
        clipsSummary = horizontal
        if summary.atTop {
            let height = summaryHeight
            dragBar.frame = .zero
            summaryScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
            scroll.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
        } else {
            dragBar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: 28)
            summaryScroll.frame = NSRect(x: 0, y: 28, width: sidebarWidth, height: max(0, bounds.height - 28))
            scroll.frame = NSRect(x: sidebarWidth, y: 0, width: max(0, bounds.width - sidebarWidth), height: bounds.height)
        }
        scroll.hasVerticalScroller = !horizontal
        summaryScroll.hasVerticalScroller = count == 0
        summary.frame = NSRect(x: 0, y: 0, width: summaryScroll.frame.width, height: summaryHeight)
        summary.needsDisplay = true
        scroll.isHidden = count == 0
        guard count > 0 else { meters.spectrogramView.isHidden = true; return }
        let viewport = scroll.contentSize
        let columns = horizontal ? count : 1
        if meters.layoutColumns != columns || meters.layoutHorizontal != horizontal {
            meters.cancelInteraction()
            scroll.contentView.scroll(to: .zero)
        }
        meters.layoutColumns = columns
        meters.layoutHorizontal = horizontal
        let rows = (count + columns - 1) / columns
        meters.setFrameSize(NSSize(width: max(viewport.width, CGFloat(columns) * 150 + CGFloat(columns - 1) * 8 + 16),
            height: horizontal ? viewport.height : max(viewport.height, CGFloat(rows) * 110 + CGFloat(rows - 1) * 8 + 14)))
        scroll.reflectScrolledClipView(scroll.contentView)
        meters.needsDisplay = true
    }
}

@MainActor
private final class AudioSummaryView: NSView {
    weak var meters: MeterView?
    /// Draws as a block across the top instead of a sidebar column.
    var atTop = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    private var headerLines: [String] { meters?.sourceLabel.components(separatedBy: " · ") ?? [] }
    private var loudnessTop: CGFloat { 14 + CGFloat(headerLines.count) * 14 }
    /// Height that shows every line; the sidebar scrolls only when the window is shorter.
    var contentHeight: CGFloat {
        guard let meters, meters.visibleMeters.contains(5) else { return loudnessTop }
        return loudnessTop + meters.loudnessMinimumHeight + 4
    }
    // Dragging moves the window; a click clears held peaks and the clip indicator.
    private var pendingClick: NSEvent?
    override func mouseDown(with event: NSEvent) { pendingClick = event }
    override func mouseDragged(with event: NSEvent) {
        guard let down = pendingClick else { return }
        pendingClick = nil
        window?.performDrag(with: down)
    }
    override func mouseUp(with event: NSEvent) {
        if pendingClick != nil { meters?.resetPeakHold() }
        pendingClick = nil
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let meters else { return }
        if atTop { drawTop(meters); return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let clip = meters.visibleMeters.contains(5) && meters.clipActive
        for (index, line) in headerLines.enumerated() {
            let width = bounds.width - 24 - (clip && index == 1 ? 40 : 0)
            (line as NSString).draw(in: NSRect(x: 12, y: 7 + CGFloat(index) * 14, width: width, height: 14),
                withAttributes: [.font: (NSFont(name: "Menlo", size: 9) ?? NSFont.systemFont(ofSize: 9)),
                                 .foregroundColor: NSColor.white.withAlphaComponent(index == 0 ? 0.8 : 0.45),
                                 .paragraphStyle: paragraph])
        }
        if clip { meters.clipBadge(in: NSRect(x: bounds.width - 46, y: 22, width: 34, height: 13)) }
        if meters.visibleMeters.contains(5) {
            meters.loudness(in: NSRect(x: 10, y: loudnessTop, width: min(180, bounds.width - 24), height: max(meters.loudnessMinimumHeight, bounds.height - loudnessTop - 4)))
        }
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 1, y: 7))
        separator.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxY - 7))
        separator.stroke()
    }

    private static func gridColumns(width: CGFloat) -> Int { width - 24 >= 520 ? 4 : 2 }

    func topHeight(width: CGFloat) -> CGFloat {
        guard let meters, meters.visibleMeters.contains(5) else { return 30 }
        return 34 + MeterView.loudnessGridHeight(columns: Self.gridColumns(width: width)) + 8
    }

    private func drawTop(_ meters: MeterView) {
        // Source sits clear of the traffic lights, readings span the width below.
        let x: CGFloat = 84
        let clip = meters.visibleMeters.contains(5) && meters.clipActive
        let lines = headerLines.isEmpty ? [] : [headerLines[0], headerLines.dropFirst().joined(separator: " · ")].filter { !$0.isEmpty }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(in: NSRect(x: x, y: lines.count == 1 ? 9 : 3 + CGFloat(index) * 13, width: max(0, bounds.width - x - 12 - (clip ? 46 : 0)), height: 14),
                withAttributes: [.font: (NSFont(name: "Menlo", size: 9) ?? NSFont.systemFont(ofSize: 9)),
                                 .foregroundColor: NSColor.white.withAlphaComponent(index == 0 ? 0.8 : 0.45),
                                 .paragraphStyle: paragraph])
        }
        if clip { meters.clipBadge(in: NSRect(x: bounds.width - 46, y: 9, width: 34, height: 13)) }
        if meters.visibleMeters.contains(5) {
            let columns = Self.gridColumns(width: bounds.width)
            meters.loudnessGrid(in: NSRect(x: 12, y: 34, width: bounds.width - 24, height: MeterView.loudnessGridHeight(columns: columns)), columns: columns)
        }
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSRect(x: 7, y: bounds.maxY - 1, width: bounds.width - 14, height: 1).fill()
    }
}

@MainActor
private final class SummaryDragBar: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
