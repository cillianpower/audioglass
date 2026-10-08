import AppKit

@MainActor
final class MeterSettingsWindow: NSWindowController {
    private let controlsMenu: NSMenu
    private let meters: MeterView
    private let orderChanged: () -> Void
    private let scroll = NSScrollView()
    private let form = SettingsDocumentView()
    private var nextY: CGFloat = 18

    init(controlsMenu: NSMenu, meters: MeterView, orderChanged: @escaping () -> Void) {
        self.controlsMenu = controlsMenu
        self.meters = meters
        self.orderChanged = orderChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Audioglass Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = window.contentView!.bounds
        scroll.documentView = form
        window.contentView?.addSubview(scroll)
        window.center()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let offset = scroll.contentView.bounds.origin
        form.subviews.forEach { $0.removeFromSuperview() }
        nextY = 18
        heading("Modules")
        label("Loudness is pinned left with audio information.", y: nextY, width: 510, size: 12)
        nextY += 28
        for (index, meter) in meters.moduleOrder.enumerated() {
            moduleRow(meter, position: index)
        }
        moduleRow(5, position: nil)
        nextY += 12
        heading("Display and Analysis")

        let layout = NSPopUpButton(frame: NSRect(x: 250, y: nextY, width: 280, height: 26))
        label("Layout", y: nextY + 4)
        for item in controlsMenu.items where item.action == NSSelectorFromString("changeLayout:") {
            addOption(item, to: layout)
        }
        form.addSubview(layout)
        nextY += 34
        for item in controlsMenu.items where item.submenu != nil && item.title != "Meters" {
            guard let submenu = item.submenu else { continue }
            label(item.title, y: nextY + 4)
            let popup = NSPopUpButton(frame: NSRect(x: 250, y: nextY, width: 280, height: 26))
            for option in submenu.items { addOption(option, to: popup) }
            form.addSubview(popup)
            nextY += 34
        }
        nextY += 10
        for title in ["Reset Section Sizes", "Reset Analysis"] {
            guard let item = controlsMenu.items.first(where: { $0.title == title }) else { continue }
            let button = NSButton(title: title, target: self, action: #selector(reset(_:)))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 24, y: nextY, width: 180, height: 28)
            button.tag = controlsMenu.items.firstIndex(of: item)!
            form.addSubview(button)
            nextY += 34
        }
        label("Shift-drag dividers to resize. Hold the spectrum to freeze it.", y: nextY + 4, width: 510, size: 11)
        form.setFrameSize(NSSize(width: 560, height: nextY + 42))
        scroll.contentView.scroll(to: NSPoint(x: offset.x, y: min(offset.y, max(0, form.frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func heading(_ title: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 14)
        heading.frame = NSRect(x: 24, y: nextY, width: 500, height: 20)
        form.addSubview(heading)
        nextY += 28
    }
    private func label(_ text: String, y: CGFloat, width: CGFloat = 218, size: CGFloat = 12) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 24, y: y, width: width, height: 18)
        form.addSubview(label)
    }
    private func moduleRow(_ meter: Int, position: Int?) {
        let check = NSButton(checkboxWithTitle: MeterView.meterNames[meter].capitalized, target: self, action: #selector(toggle(_:)))
        check.tag = meter
        check.state = meters.visibleMeters.contains(meter) ? .on : .off
        check.isEnabled = !meters.visibleMeters.contains(meter) || meters.visibleMeters.count > 1
        check.frame = NSRect(x: 24, y: nextY, width: 215, height: 26)
        form.addSubview(check)
        if let position {
            for (direction, title) in ["Move Up", "Move Down"].enumerated() {
                let button = NSButton(title: title, target: self, action: #selector(move(_:)))
                button.bezelStyle = .rounded
                button.tag = position * 2 + direction
                button.isEnabled = direction == 0 ? position > 0 : position < meters.moduleOrder.count - 1
                button.frame = NSRect(x: 310 + CGFloat(direction) * 110, y: nextY, width: 105, height: 26)
                button.setAccessibilityLabel("\(title): \(MeterView.meterNames[meter].capitalized)")
                form.addSubview(button)
            }
        }
        nextY += 30
    }
    private func addOption(_ source: NSMenuItem, to popup: NSPopUpButton) {
        popup.addItem(withTitle: source.title)
        popup.lastItem?.representedObject = source
        if source.state == .on { popup.select(popup.lastItem) }
        popup.target = self
        popup.action = #selector(selectOption(_:))
    }
    private func invoke(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    @objc private func toggle(_ sender: NSButton) {
        guard let item = controlsMenu.items.first(where: { $0.title == "Meters" })?.submenu?.items.first(where: { $0.tag == sender.tag }) else { return }
        invoke(item)
        refresh()
    }
    @objc private func move(_ sender: NSButton) {
        let position = sender.tag / 2
        let destination = position + (sender.tag % 2 == 0 ? -1 : 1)
        guard meters.moduleOrder.indices.contains(destination) else { return }
        meters.moduleOrder.swapAt(position, destination)
        orderChanged()
        refresh()
    }
    @objc private func selectOption(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem?.representedObject as? NSMenuItem else { return }
        invoke(item)
    }
    @objc private func reset(_ sender: NSButton) { invoke(controlsMenu.items[sender.tag]) }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
