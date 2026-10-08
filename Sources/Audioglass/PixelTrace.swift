import AppKit

// Keep both extrema in each physical pixel column. Large FFT/scope snapshots
// retain narrow peaks without issuing thousands of invisible path segments.
@MainActor
struct PixelTrace {
    let path = NSBezierPath()
    let scale: CGFloat
    private var column: Int?
    private var low = NSPoint.zero
    private var high = NSPoint.zero
    private var lowIndex = 0
    private var highIndex = 0
    private var index = 0
    private var started = false

    init(scale: CGFloat) { self.scale = scale }

    mutating func append(_ point: NSPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        let next = Int(floor(point.x * scale))
        if next != column {
            finish()
            column = next
            low = point
            high = point
            lowIndex = 0
            highIndex = 0
            index = 0
        } else {
            index += 1
            if point.y < low.y { low = point; lowIndex = index }
            if point.y > high.y { high = point; highIndex = index }
        }
    }

    mutating func finish() {
        guard column != nil else { return }
        let first = lowIndex <= highIndex ? low : high
        let second = lowIndex <= highIndex ? high : low
        if started { path.line(to: first) }
        else { path.move(to: first); started = true }
        if second != first { path.line(to: second) }
        column = nil
    }
}
