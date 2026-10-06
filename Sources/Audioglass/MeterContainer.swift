import AppKit

// Keep every enabled meter usable even at the native 280x150 minimum. Normal
// strip/column sizes fit without scrolling; smaller windows scroll naturally.
@MainActor
final class MeterContainer: NSView {
    private let scroll = NSScrollView()
    private let meters: MeterView
    private var automaticHorizontal: Bool?
    init(meters: MeterView) {
        self.meters = meters
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = meters
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let viewport = scroll.contentSize
        let count = meters.visibleMeters.count
        let columns: Int
        if meters.arrangement == 1 { columns = count }
        else if meters.arrangement == 2 { columns = 1 }
        else {
            // Pick a single row or column from the viewport, not the larger
            // scrollable document. A small dead band avoids flipping repeatedly
            // as the user drags a nearly square window through the boundary.
            let ratio = viewport.width / max(1, viewport.height)
            if automaticHorizontal == nil { automaticHorizontal = ratio >= 1 }
            else if ratio >= 1.1 { automaticHorizontal = true }
            else if ratio <= 0.9 { automaticHorizontal = false }
            columns = automaticHorizontal == true ? count : 1
        }
        let changedOrientation = meters.layoutColumns != columns
        let rows = (count + columns - 1) / columns
        meters.layoutColumns = columns
        meters.setFrameSize(NSSize(width: max(viewport.width, CGFloat(columns) * 150 + 16),
            height: max(viewport.height, CGFloat(rows) * 110 + 40)))
        if changedOrientation {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        meters.needsDisplay = true
    }
}
