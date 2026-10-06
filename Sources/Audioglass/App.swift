import AppKit
import DSPBridge
import AVFoundation

@main
@MainActor
struct Audioglass {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let meters = MeterView()
    private var meterContainer: MeterContainer!
    private var timer: Timer?
    private let analysisQueue = DispatchQueue(label: "com.cillianpower.audioglass.analysis", qos: .userInitiated)
    private let engine = AnalysisEngine()
    private var analysisInFlight = false
    private let capture = AudioCapture()
    private var source = AudioSource.stopped
    private var sourceMenu = NSMenu(title: "Audio Source")
    private var configurationTimer: Timer?
    private var sourceGeneration = 0
    private var lastReceived: UInt64 = 0
    private var settings = MeterSettings()
    private let viewMenu = NSMenu(title: "View")
    private var meterMenu = NSMenu(title: "Meters")
    private var smoothing = Float(UserDefaults.standard.double(forKey: "SpectrumSmoothing"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1050, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Audioglass"
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        window.level = .normal
        window.contentMinSize = NSSize(width: 280, height: 150)
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("AudioglassWindowStudy")

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 0
        glass.tintColor = NSColor.black.withAlphaComponent(0.22)
        meterContainer = MeterContainer(meters: meters)
        glass.contentView = meterContainer
        window.contentView = glass
        if !window.setFrameUsingName("AudioglassWindowStudy") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer(timeInterval: 1.0 / 30, target: self,
                      selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        configurationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.capture.configurationChanged() { self.selectSource(self.source) }
                if let ring = self.capture.transport {
                    let received = ag_transport_received(ring)
                    let progressing = received > self.lastReceived
                    self.lastReceived = received
                    self.meters.sourceLabel = "\(self.source.name.uppercased()) · \(Int(self.capture.format.mSampleRate)) Hz · \(progressing ? "CAPTURING" : "WAITING FOR STREAM")"
                }
            }
        }
        let saved = UserDefaults.standard.string(forKey: "AudioSource") ?? "stopped"
        if saved != "stopped" {
            selectSource(AudioCapture.sources().first { $0.id == saved } ?? AudioSource(id: saved, name: saved))
        }
    }

    @objc private func tick() {
        guard !analysisInFlight else { return }
        analysisInFlight = true
        let smoothing = smoothing
        let settings = settings
        let engine = engine
        let generation = sourceGeneration
        let input = capture.transport.map { CaptureInput(transport: $0, sampleRate: Float(capture.format.mSampleRate)) }
        analysisQueue.async { [weak self] in
            let frame = engine.process(input: input, settings: settings, smoothing: smoothing)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.sourceGeneration == generation else { return }
                self.meters.frameData = frame
                if self.window.isVisible && !self.window.isMiniaturized { self.meters.spectrogramView.update(frame.spectrogram) }
                self.meters.needsDisplay = self.window.isVisible && !self.window.isMiniaturized
                self.analysisInFlight = false
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        configurationTimer?.invalidate()
        analysisQueue.sync {}
        capture.stop()
    }

    private func selectSource(_ selected: AudioSource) {
        sourceGeneration += 1
        lastReceived = 0
        analysisQueue.sync { engine.reset() }
        analysisInFlight = false
        source = selected
        do {
            try capture.start(selected)
            UserDefaults.standard.set(selected.id, forKey: "AudioSource")
            meters.sourceLabel = selected == .stopped ? "STOPPED · SELECT AN AUDIO SOURCE" : "\(selected.name.uppercased()) · STARTING"
        } catch {
            meters.sourceLabel = "CAPTURE UNAVAILABLE · RETRY IN AUDIO SOURCE"
            let alert = NSAlert()
            alert.messageText = "Audio capture could not start"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
        meters.frameData = AnalysisFrame(frequencies: [], levels: [], waveform: [])
        meters.setAccessibilityLabel("Audioglass audio meters. Source: \(selected.name). Select a source in the Audio Source menu.")
        rebuildSourceMenu()
        meters.needsDisplay = true
    }

    @objc private func changeSource(_ sender: NSMenuItem) {
        guard let selected = sender.representedObject as? String else { return }
        let value = AudioSource(id: selected, name: sender.title)
        if selected.hasPrefix("input:") && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let generation = sourceGeneration
            Task { @MainActor in
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard generation == sourceGeneration else { return }
                if allowed { selectSource(value) }
                else { meters.sourceLabel = "INPUT ACCESS DENIED · SELECT ANOTHER SOURCE"; meters.needsDisplay = true }
            }
        } else { selectSource(value) }
    }

    private func rebuildSourceMenu() {
        sourceMenu.removeAllItems()
        var sources = AudioCapture.sources()
        if !sources.contains(where: { $0.id == source.id }) { sources.append(source) }
        for value in sources {
            let item = sourceMenu.addItem(withTitle: value.name, action: #selector(changeSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.id
            item.state = value.id == source.id ? .on : .off
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeMenus() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Audioglass", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Audioglass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        rebuildSourceMenu()
        sourceMenu.delegate = self
        let sourceItem = NSMenuItem(title: "Audio Source", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        main.addItem(sourceItem)


        for (title, key, tag) in [("Automatic Layout", "1", 0), ("Horizontal Layout", "2", 1), ("Vertical Layout", "3", 2)] {
            let item = viewMenu.addItem(withTitle: title, action: #selector(changeLayout(_:)), keyEquivalent: key)
            item.target = self
            item.tag = tag
            item.state = tag == meters.arrangement ? .on : .off
        }
        viewMenu.addItem(.separator())
        for (index, name) in MeterView.meterNames.enumerated() {
            let item = meterMenu.addItem(withTitle: name.capitalized, action: #selector(toggleMeter(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = meters.visibleMeters.contains(index) ? .on : .off
        }
        let meterItem = NSMenuItem(title: "Meters", action: nil, keyEquivalent: "")
        meterItem.submenu = meterMenu
        viewMenu.addItem(meterItem)
        viewMenu.addItem(withTitle: "Reset Analysis", action: #selector(resetAnalysis(_:)), keyEquivalent: "r").target = self
        let smoothingMenu = NSMenu(title: "Spectrum Smoothing")
        let selected = [Float(0), 0.25, 0.65, 0.9, -1].firstIndex(of: smoothing) ?? 0
        for (index, title) in ["Off — Raw FFT", "Light", "Medium", "High", "Peak Hold — 12 dB/s"].enumerated() {
            let item = smoothingMenu.addItem(withTitle: title, action: #selector(changeSmoothing(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selected ? .on : .off
        }
        smoothing = [Float(0), 0.25, 0.65, 0.9, -1][selected]
        meters.smoothingLabel = ["OFF", "LIGHT", "MEDIUM", "HIGH", "PEAK HOLD"][selected]
        let smoothingItem = NSMenuItem(title: "Spectrum Smoothing", action: nil, keyEquivalent: "")
        smoothingItem.submenu = smoothingMenu
        viewMenu.addItem(smoothingItem)
        addSettingMenu(to: viewMenu, title: "Spectrum / Scope Channel", key: "AnalysisChannel", values: [("Mid", 0), ("Side", 1), ("Left", 2), ("Right", 3)], selected: settings.channel)
        addSettingMenu(to: viewMenu, title: "Spectrum FFT Size", key: "FFTSize", values: [("4096", 4096), ("8192", 8192), ("16384", 16384), ("32768", 32768)], selected: settings.fftSize)
        addSettingMenu(to: viewMenu, title: "Spectrum Range", key: "SpectrumFloor", values: [("−60 to 0 dB", -60), ("−90 to 0 dB", -90), ("−120 to 0 dB", -120)], selected: settings.floor)
        addSettingMenu(to: viewMenu, title: "Spectrum Weighting", key: "AWeighting", values: [("Unweighted", 0), ("A-weighted", 1)], selected: settings.weighted ? 1 : 0)
        addSettingMenu(to: viewMenu, title: "Oscilloscope Trigger", key: "ScopeCycles", values: [("Zero Crossing — 50 ms", 0), ("Stable — 1 Cycle", 1), ("Stable — 2 Cycles", 2), ("Stable — 4 Cycles", 4)], selected: settings.cycles)
        addSettingMenu(to: viewMenu, title: "Waveform History", key: "WaveSpeed", values: [("2.56 Seconds", 400), ("5.12 Seconds", 200), ("10.24 Seconds", 100)], selected: settings.waveSpeed)
        meters.settings = settings
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Meter Strip", action: #selector(sizePreset(_:)), keyEquivalent: "").target = self
        let columnItem = windowMenu.addItem(withTitle: "Meter Column", action: #selector(sizePreset(_:)), keyEquivalent: "")
        columnItem.target = self
        columnItem.tag = 1
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Audioglass",
            .applicationVersion: "0.2.0",
            .credits: NSAttributedString(string: "Native macOS glass audio meters.\nDSP adapted from OpenMeters 1.15.2 by Maika Namuo.\nGPL-3.0-or-later; source attribution and license are included in the app bundle.")
        ])
    }

    @objc private func sizePreset(_ sender: NSMenuItem) {
        let visible = window.screen?.visibleFrame.size ?? NSSize(width: 1200, height: 900)
        let size = sender.tag == 0 ? NSSize(width: min(1200, visible.width), height: 240)
            : NSSize(width: 350, height: min(900, visible.height))
        window.setContentSize(size)
        meters.arrangement = 0
        UserDefaults.standard.set(meters.arrangement, forKey: "StripLayoutMode")
        viewMenu.items.filter { $0.action == #selector(changeLayout(_:)) }.forEach { $0.state = $0.tag == meters.arrangement ? .on : .off }
        meterContainer.needsLayout = true
        meters.needsDisplay = true
    }

    private func addSettingMenu(to menu: NSMenu, title: String, key: String, values: [(String, Int)], selected: Int) {
        let submenu = NSMenu(title: title)
        for (name, value) in values {
            let item = submenu.addItem(withTitle: name, action: #selector(changeMeterSetting(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.representedObject = key
            item.state = value == selected ? .on : .off
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func changeMeterSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(sender.tag, forKey: key)
        settings = MeterSettings()
        meters.settings = settings
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        meters.needsDisplay = true
    }

    @objc private func resetAnalysis(_ sender: NSMenuItem) {
        selectSource(source)
    }

    @objc private func toggleMeter(_ sender: NSMenuItem) {
        if meters.visibleMeters.contains(sender.tag) {
            guard meters.visibleMeters.count > 1 else { return }
            meters.visibleMeters.removeAll { $0 == sender.tag }
        } else {
            meters.visibleMeters.append(sender.tag)
            meters.visibleMeters.sort()
        }
        UserDefaults.standard.set(meters.visibleMeters, forKey: "VisibleMeters")
        sender.state = meters.visibleMeters.contains(sender.tag) ? .on : .off
        meterContainer?.needsLayout = true
        meters.needsDisplay = true
    }

    @objc private func changeLayout(_ sender: NSMenuItem) {
        meterContainer?.needsLayout = true
        meters.arrangement = sender.tag
        UserDefaults.standard.set(sender.tag, forKey: "StripLayoutMode")
        sender.menu?.items.filter { $0.action == #selector(changeLayout(_:)) }.forEach { $0.state = $0 === sender ? .on : .off }
        meters.needsDisplay = true
    }

    @objc private func changeSmoothing(_ sender: NSMenuItem) {
        smoothing = [Float(0), 0.25, 0.65, 0.9, -1][sender.tag]
        UserDefaults.standard.set(Double(smoothing), forKey: "SpectrumSmoothing")
        meters.smoothingLabel = ["OFF", "LIGHT", "MEDIUM", "HIGH", "PEAK HOLD"][sender.tag]
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        meters.needsDisplay = true
    }
}

@MainActor
final class MeterView: NSView {
    var sourceLabel = "STOPPED · SELECT AN AUDIO SOURCE"
    var settings = MeterSettings()
    static let meterNames = ["SPECTRUM", "OSCILLOSCOPE", "SPECTROGRAM", "WAVEFORM", "STEREOMETER", "LOUDNESS"]
    var visibleMeters: [Int] = {
        let saved = (UserDefaults.standard.array(forKey: "VisibleMeters") as? [Int] ?? Array(0..<6)).filter { (0..<6).contains($0) }
        return saved.isEmpty ? Array(0..<6) : Array(Set(saved)).sorted()
    }()
    let spectrogramView = SpectrogramView()
    var layoutColumns = 6
    var arrangement = UserDefaults.standard.integer(forKey: "StripLayoutMode")
    var smoothingLabel = "OFF"
    var frameData = AnalysisFrame(frequencies: [], levels: [], waveform: []) {
        didSet { hoverOverlay.needsDisplay = true }
    }
    private var hoverPoint: NSPoint?
    private var graphs: [Int: NSRect] = [:]
    private let hoverOverlay = MeterHoverOverlay()
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
        if let window, window.isKeyWindow {
            hoverPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        hoverOverlay.needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        mouseMoved(with: event)
        super.mouseDown(with: event)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        hoverOverlay.needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        hoverOverlay.needsDisplay = true
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(spectrogramView)
        hoverOverlay.frame = bounds
        hoverOverlay.autoresizingMask = [.width, .height]
        hoverOverlay.render = { [weak self] in self?.drawHover() }
        addSubview(hoverOverlay)
        setAccessibilityElement(true)
        setAccessibilityLabel("Audioglass audio meters. Select system audio or an application in the Audio Source menu.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 8, dy: 7)
        guard area.width > 0, area.height > 40 else { return }
        let header = area.width < 500 ? sourceLabel.components(separatedBy: " · ").first ?? sourceLabel
            : "\(sourceLabel) · SMOOTHING \(smoothingLabel)"
        text(header, at: NSPoint(x: area.minX + 80, y: area.minY + 2), size: 9,
            color: .white.withAlphaComponent(0.5), width: max(1, area.width - 80))
        let plots = NSRect(x: area.minX, y: area.minY + 26, width: area.width, height: area.height - 26)
        let count = visibleMeters.count
        let columns = max(1, layoutColumns)
        let rows = (count + columns - 1) / columns
        let gap: CGFloat = 8
        let width = (plots.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (plots.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        graphs.removeAll(keepingCapacity: true)
        spectrogramView.isHidden = !visibleMeters.contains(2)
        for (position, meter) in visibleMeters.enumerated() {
            let rect = NSRect(x: plots.minX + CGFloat(position % columns) * (width + gap),
                y: plots.minY + CGFloat(position / columns) * (height + gap), width: width, height: height)
            panel(Self.meterNames[meter], rect: rect) { graph in
                graphs[meter] = graph
                switch meter {
                case 0: spectrum(in: graph)
                case 1: scope(in: graph)
                case 2: spectrogramView.frame = graph
                case 3: history(in: graph)
                case 4: stereo(in: graph)
                default: loudness(in: graph)
                }
            }
        }
        hoverOverlay.needsDisplay = true
    }

    private func panel(_ name: String, rect: NSRect, draw: (NSRect) -> Void) {
        text(name, at: NSPoint(x: rect.minX + 4, y: rect.minY + 2), size: 9, color: .white.withAlphaComponent(0.55))
        let graph = NSRect(x: rect.minX + 4, y: rect.minY + 20, width: rect.width - 8, height: rect.height - 36)
        guard graph.width > 1, graph.height > 1 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: graph).addClip()
        NSColor.white.withAlphaComponent(0.075).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for i in 1..<5 {
            let y = graph.minY + graph.height * CGFloat(i) / 5
            grid.move(to: NSPoint(x: graph.minX, y: y))
            grid.line(to: NSPoint(x: graph.maxX, y: y))
        }
        grid.stroke()
        draw(graph)
        NSGraphicsContext.restoreGraphicsState()
        if name == "SPECTRUM" {
            let maximum = asinh(Double(frameData.frequencies.last ?? 24000) / 20.0)
            for (frequency, label) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
                let x = graph.minX + graph.width * asinh(frequency / 20) / maximum
                text(label, at: NSPoint(x: x - 7, y: graph.maxY + 3), size: 8, color: .white.withAlphaComponent(0.4))
            }
        }
    }

    private func spectrum(in rect: NSRect) {
        let path = NSBezierPath()
        // OpenMeters' logarithmic axis uses an asinh knee at 20 Hz.
        let maximum = asinh(Double(frameData.frequencies.last ?? 24000) / 20.0)
        for (i, pair) in zip(frameData.frequencies, frameData.levels).enumerated() {
            let x = asinh(Double(pair.0) / 20.0) / maximum
            let level = min(1, max(0, Double(pair.1 - Float(settings.floor)) / Double(-settings.floor)))
            let point = NSPoint(x: rect.minX + rect.width * x, y: rect.maxY - rect.height * level)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.white.withAlphaComponent(0.92).setStroke()
        path.lineWidth = 1
        path.lineJoinStyle = .miter
        path.stroke()
        for frequency in [100.0, 1000.0, 10000.0] {
            let x = rect.minX + rect.width * asinh(frequency / 20) / maximum
            NSColor.white.withAlphaComponent(0.08).setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 0.5
            grid.move(to: NSPoint(x: x, y: rect.minY))
            grid.line(to: NSPoint(x: x, y: rect.maxY))
            grid.stroke()
        }
    }

    private func scope(in rect: NSRect) {
        guard frameData.waveform.count > 1 else { return }
        let path = NSBezierPath()
        for (i, sample) in frameData.waveform.enumerated() {
            let x = Double(i) / Double(frameData.waveform.count - 1)
            let point = NSPoint(x: rect.minX + rect.width * x, y: rect.midY - Double(sample) * rect.height * 0.5)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.white.withAlphaComponent(0.92).setStroke()
        path.lineWidth = 1
        path.lineJoinStyle = .miter
        path.stroke()
    }

    private func history(in rect: NSRect) {
        let count = frameData.history.count / 4
        guard count > 0 else { return }
        for channel in 0..<2 {
            let middle = rect.minY + rect.height * (channel == 0 ? 0.25 : 0.75)
            let path = NSBezierPath()
            for column in 0..<count {
                let x = rect.maxX - CGFloat(count - column) / 1024 * rect.width
                let low = CGFloat(frameData.history[column * 4 + channel * 2])
                let high = CGFloat(frameData.history[column * 4 + channel * 2 + 1])
                path.move(to: NSPoint(x: x, y: middle - high * rect.height * 0.23))
                path.line(to: NSPoint(x: x, y: middle - low * rect.height * 0.23))
            }
            NSColor.white.withAlphaComponent(channel == 0 ? 0.9 : 0.55).setStroke()
            path.lineWidth = 0.7
            path.stroke()
        }
        text(String(format: "L / R · %.2f s", 1024.0 / Double(settings.waveSpeed)), at: NSPoint(x: rect.minX + 3, y: rect.minY + 2), size: 8, color: .white.withAlphaComponent(0.45))
    }

    private func stereo(in rect: NSRect) {
        let radius = min(rect.width, rect.height - 18) * 0.48
        guard radius > 0 else { return }
        let center = NSPoint(x: rect.midX, y: rect.minY + (rect.height - 18) / 2)
        NSColor.white.withAlphaComponent(0.1).setStroke()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).stroke()
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: center.x, y: center.y - radius))
        axis.line(to: NSPoint(x: center.x, y: center.y + radius))
        axis.stroke()
        let path = NSBezierPath()
        for index in stride(from: 0, to: frameData.stereo.count - 1, by: 2) {
            let left = CGFloat(frameData.stereo[index])
            let right = CGFloat(frameData.stereo[index + 1])
            let point = NSPoint(x: center.x + (right - left) * radius / sqrt(2),
                y: center.y - (left + right) * radius / sqrt(2))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.white.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 0.7
        path.stroke()
        if frameData.metrics.count == 7 {
            let value = frameData.metrics[6]
            text(String(format: "CORR %+.2f", value), at: NSPoint(x: rect.minX + 2, y: rect.maxY - 13), size: 9, color: .white.withAlphaComponent(0.7))
        }
    }

    private func loudness(in rect: NSRect) {
        guard frameData.metrics.count == 7 else { return }
        let metrics = frameData.metrics
        let lineHeight = min(24, max(17, rect.height / 5))
        for (index, pair) in [("M", metrics[0]), ("S", metrics[1]), ("RMS L", metrics[2]), ("RMS R", metrics[3])].enumerated() {
            let y = rect.minY + CGFloat(index) * lineHeight
            let value = pair.1.isFinite && pair.1 > -99.8 ? String(format: "%.1f", pair.1) : "−∞"
            text("\(pair.0)  \(value) \(index < 2 ? "LUFS" : "dBFS")", at: NSPoint(x: rect.minX + 2, y: y), size: 10, color: .white.withAlphaComponent(0.85))
            let bar = NSRect(x: rect.minX + 2, y: y + 14, width: rect.width * CGFloat(max(0, min(1, (pair.1 + 60) / 60))), height: 2)
            NSColor.white.withAlphaComponent(0.55).setFill()
            bar.fill()
        }
        if rect.height > 75 {
            let left = metrics[4] > -99.8 ? String(format: "%.1f", metrics[4]) : "−∞"
            let right = metrics[5] > -99.8 ? String(format: "%.1f", metrics[5]) : "−∞"
            text("TP \(left) / \(right) dBTP",
                at: NSPoint(x: rect.minX + 2, y: rect.minY + lineHeight * 4), size: 9, color: .white.withAlphaComponent(0.6))
        }
    }

    private func frequencyLabel(_ hz: Double) -> String {
        guard hz > 0, hz.isFinite else { return "DC" }
        let midi = 69 + 12 * log2(hz / 440)
        let note = Int(midi.rounded())
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let name = names[(note % 12 + 12) % 12]
        return String(format: "%.1f Hz · %@%d %+.0f¢", hz, name, Int(floor(Double(note) / 12)) - 1, (midi - Double(note)) * 100)
    }

    private func amplitudeLabel(_ sample: Float) -> String {
        let db = abs(sample) > 0 ? String(format: "%.1f dBFS", 20 * log10(abs(sample))) : "−∞ dBFS"
        return String(format: "%+.3f · %@", sample, db)
    }

    private func drawHover() {
        guard let window else { return }
        let point = hoverPoint ?? convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point),
              let (meter, rect) = graphs.first(where: { $0.key < 4 && $0.value.contains(point) }) else { return }
        let x = max(0, min(1, (point.x - rect.minX) / rect.width))
        let y = max(0, min(1, (point.y - rect.minY) / rect.height))
        let timing = frameData.timing
        let rate = Double(timing[0])
        var lines: [String] = []
        var marker: NSPoint?
        switch meter {
        case 0:
            let hz = sinh(Double(x) * asinh(Double(frameData.frequencies.last ?? Float(rate / 2)) / 20)) * 20
            if let index = frameData.frequencies.indices.min(by: {
                abs(Double(frameData.frequencies[$0]) - hz) < abs(Double(frameData.frequencies[$1]) - hz)
            }), index < frameData.levels.count {
                let frequency = Double(frameData.frequencies[index])
                let level = frameData.levels[index]
                lines = [frequencyLabel(frequency), String(format: "%.1f dB%@ · %@", level,
                    settings.weighted ? "(A)" : "FS", ["MID", "SIDE", "LEFT", "RIGHT"][settings.channel])]
                marker = NSPoint(x: rect.minX + rect.width * asinh(frequency / 20) / asinh(Double(frameData.frequencies.last ?? 24000) / 20),
                    y: rect.maxY - rect.height * CGFloat(max(0, min(1, (level - Float(settings.floor)) / Float(-settings.floor)))))
            } else { lines = [frequencyLabel(hz), "Waiting for spectrum"] }
        case 1:
            if frameData.waveform.count > 1 {
                let index = Int((x * CGFloat(frameData.waveform.count - 1)).rounded())
                let sample = frameData.waveform[index]
                lines = [String(format: "%.2f ms · %@", Double(index) / Double(frameData.waveform.count - 1) * Double(timing[1]) * 1000,
                    ["MID", "SIDE", "LEFT", "RIGHT"][settings.channel]), amplitudeLabel(sample),
                    settings.cycles == 0 ? "Zero-crossing trigger" : timing[2] > 0 ? frequencyLabel(Double(timing[2])) : "No stable pitch · free running"]
                marker = NSPoint(x: rect.minX + CGFloat(index) / CGFloat(frameData.waveform.count - 1) * rect.width,
                    y: rect.midY - CGFloat(sample) * rect.height * 0.5)
            } else { lines = ["Waiting for oscilloscope"] }
        case 2:
            let column = min(511, Int(x * 512))
            let row = min(191, Int(y * 192))
            let hz = sinh(Double(191 - row) / 191 * asinh(rate / 2 / 20)) * 20
            lines = [frequencyLabel(hz), String(format: "%.3f s ago · MID", Double(511 - column) * Double(timing[3]))]
            if column >= 512 - Int(timing[4]), frameData.spectrogram.count == 512 * 192 {
                let pixel = frameData.spectrogram[row * 512 + column]
                lines.append(pixel == 0 ? "≤ −100 dBFS" : String(format: "≈ %.1f dBFS · row peak", Double(pixel) / 255 * 100 - 100))
            } else { lines.append("No history here yet") }
        default:
            let count = frameData.history.count / 4
            let column = Int(x * 1024) - (1024 - count)
            let channel = y < 0.5 ? 0 : 1
            lines = [String(format: "%.3f s ago · %@", Double(1024 - min(1023, Int(x * 1024))) / Double(settings.waveSpeed), channel == 0 ? "LEFT" : "RIGHT")]
            if column >= 0 && column < count {
                let low = frameData.history[column * 4 + channel * 2]
                let high = frameData.history[column * 4 + channel * 2 + 1]
                let peak = max(abs(low), abs(high))
                lines.append(String(format: "min %+.3f · max %+.3f", low, high))
                lines.append(peak > 0 ? String(format: "Peak %.1f dBFS", 20 * log10(peak)) : "Peak −∞ dBFS")
            } else { lines.append("No history here yet") }
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let guide = NSBezierPath()
        guide.lineWidth = 0.5
        guide.setLineDash([3, 3], count: 2, phase: 0)
        guide.move(to: NSPoint(x: point.x, y: rect.minY))
        guide.line(to: NSPoint(x: point.x, y: rect.maxY))
        if meter == 2 {
            guide.move(to: NSPoint(x: rect.minX, y: point.y))
            guide.line(to: NSPoint(x: rect.maxX, y: point.y))
        }
        guide.stroke()
        if let marker {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: marker.x - 2, y: marker.y - 2, width: 4, height: 4)).fill()
        }
        let height = CGFloat(lines.count) * 13 + 8
        let box = NSRect(x: rect.minX + 2, y: point.y < rect.midY ? rect.maxY - height - 2 : rect.minY + 2,
            width: rect.width - 4, height: height)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        for (index, line) in lines.enumerated() {
            text(line, at: NSPoint(x: box.minX + 5, y: box.minY + 4 + CGFloat(index) * 13),
                size: 9, color: .white.withAlphaComponent(0.95), width: box.width - 10)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func text(_ value: String, at point: NSPoint, size: CGFloat, color: NSColor, width: CGFloat? = nil) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraph,
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color
        ]
        if let width {
            (value as NSString).draw(in: NSRect(x: point.x, y: point.y, width: width, height: size * 1.7), withAttributes: attributes)
        } else { (value as NSString).draw(at: point, withAttributes: attributes) }
    }
}

@MainActor
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sourceMenu { rebuildSourceMenu() }
    }
}

// Transparent AppKit overlay above Metal; pointer events remain with the meters.
@MainActor
private final class MeterHoverOverlay: NSView {
    var render: (() -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { render?() }
}
