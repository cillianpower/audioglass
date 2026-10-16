import AppKit
import QuartzCore
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
    private var displayLink: CADisplayLink?
    private var pendingFrame: AnalysisFrame?
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
    private var settingsWindow: MeterSettingsWindow?
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
        window.isMovableByWindowBackground = false
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
        displayLink = window.displayLink(target: self, selector: #selector(displayTick(_:)))
        applyFrameRate()
        displayLink?.add(to: .main, forMode: .common)
        // Keep capture/history progressing when the window's display link stops.
        timer = Timer(timeInterval: 1.0 / 30, target: self,
                      selector: #selector(backgroundTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        configurationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.capture.configurationChanged() { self.selectSource(self.source) }
                if let ring = self.capture.transport {
                    let received = ag_transport_received(ring)
                    let progressing = received > self.lastReceived
                    self.lastReceived = received
                    self.meters.sourceLabel = "\(self.source.name.uppercased()) · \(String(format: "%g", self.capture.format.mSampleRate / 1000)) kHz" + (progressing ? "" : " · WAITING FOR STREAM")
                }
            }
        }
        let saved = UserDefaults.standard.string(forKey: "AudioSource") ?? "stopped"
        if saved != "stopped" {
            selectSource(AudioCapture.sources().first { $0.id == saved } ?? AudioSource(id: saved, name: saved))
        }
    }

    private func applyFrameRate() {
        let fps = Float(settings.frameRate)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    private var canDraw: Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard canDraw else { return }
        if let frame = pendingFrame {
            pendingFrame = nil
            meters.frameData = frame
        }
        meters.spectrogramView.drawIfNeeded()
        meters.advanceNormalization(at: link.targetTimestamp)
        meters.needsDisplay = true
        tick()
    }

    @objc private func backgroundTick() {
        guard !canDraw else { return }
        tick()
    }

    private func tick() {
        guard !analysisInFlight else { return }
        analysisInFlight = true
        let smoothing = smoothing
        let settings = settings
        let geometry = meters.spectrogramGeometry
        let engine = engine
        let generation = sourceGeneration
        let input = capture.transport.map { CaptureInput(transport: $0, sampleRate: Float(capture.format.mSampleRate)) }
        analysisQueue.async { [weak self] in
            var frame = engine.process(input: input, settings: settings, geometry: geometry, smoothing: smoothing)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.sourceGeneration == generation else { return }
                // Spectrogram deltas apply even if this frame is never presented.
                self.meters.spectrogramView.apply(frame.spectrogram)
                frame.spectrogram = nil
                self.pendingFrame = frame
                self.analysisInFlight = false
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) { meters.cancelInteraction() }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        displayLink?.invalidate()
        configurationTimer?.invalidate()
        analysisQueue.sync {}
        capture.stop()
    }

    private func selectSource(_ selected: AudioSource) {
        meters.cancelInteraction()
        meters.resetNormalization()
        pendingFrame = nil
        sourceGeneration += 1
        lastReceived = 0
        analysisQueue.sync { engine.reset() }
        meters.spectrogramView.clear()
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
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
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
        viewMenu.addItem(withTitle: "Reset Section Sizes", action: #selector(resetSectionSizes(_:)), keyEquivalent: "").target = self
        viewMenu.addItem(withTitle: "Reset Analysis", action: #selector(resetAnalysis(_:)), keyEquivalent: "r").target = self
        addSettingMenu(to: viewMenu, title: "Frame Rate", key: "FrameRate", values: [("60 fps", 60), ("120 fps", 120)], selected: settings.frameRate)
        let channels = [("Mid", 1), ("Side", 2), ("Left", 3), ("Right", 4)]
        let normalization = [("Off — Actual Amplitude", 0), ("On — Fit to View", 1)]

        let spectrumMenu = NSMenu(title: "Spectrum")
        let smoothingMenu = NSMenu(title: "Smoothing")
        let selected = [Float(0), 0.25, 0.65, 0.9, -1].firstIndex(of: smoothing) ?? 0
        for (index, title) in ["Off — Raw FFT", "Light", "Medium", "High", "Peak Hold — 12 dB/s"].enumerated() {
            let item = smoothingMenu.addItem(withTitle: title, action: #selector(changeSmoothing(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selected ? .on : .off
        }
        smoothing = [Float(0), 0.25, 0.65, 0.9, -1][selected]
        meters.smoothingLabel = ["OFF", "LIGHT", "MEDIUM", "HIGH", "PEAK HOLD"][selected]
        let smoothingItem = NSMenuItem(title: "Smoothing", action: nil, keyEquivalent: "")
        smoothingItem.submenu = smoothingMenu
        spectrumMenu.addItem(smoothingItem)
        addSettingMenu(to: spectrumMenu, title: "Source", key: "AnalysisChannel", values: [("Mid", 0), ("Side", 1), ("Left", 2), ("Right", 3)], selected: settings.channel)
        addSettingMenu(to: spectrumMenu, title: "Second Trace", key: "SpectrumSecondary", values: [("None", 0)] + channels, selected: settings.spectrumSecondary)
        addSettingMenu(to: spectrumMenu, title: "FFT Size", key: "FFTSize", values: [("4096", 4096), ("8192", 8192), ("16384", 16384), ("32768", 32768)], selected: settings.fftSize)
        addSettingMenu(to: spectrumMenu, title: "Range", key: "SpectrumFloor", values: [("−60 to 0 dB", -60), ("−90 to 0 dB", -90), ("−120 to 0 dB", -120)], selected: settings.floor)
        addSettingMenu(to: spectrumMenu, title: "Weighting", key: "AWeighting", values: [("Unweighted", 0), ("A-weighted", 1)], selected: settings.weighted ? 1 : 0)
        addSettingMenu(to: spectrumMenu, title: "Frequency Scale", key: "SpectrumScale", values: [("Linear", 0), ("Logarithmic", 1), ("ERB", 2)], selected: settings.spectrumScale)
        addSettingMenu(to: spectrumMenu, title: "Peak Label", key: "SpectrumPeakLabel", values: [("Off", 0), ("On", 1)], selected: settings.spectrumPeakLabel)
        addGroup(spectrumMenu, to: viewMenu)

        let scopeMenu = NSMenu(title: "Oscilloscope")
        addSettingMenu(to: scopeMenu, title: "Channel", key: "ScopeChannel", values: channels, selected: settings.scopeChannel)
        addSettingMenu(to: scopeMenu, title: "Second Channel", key: "ScopeChannel2", values: [("None", 0)] + channels, selected: settings.scopeChannel2)
        addSettingMenu(to: scopeMenu, title: "Trigger", key: "ScopeCycles", values: [("Zero Crossing", 0), ("Stable — 1 Cycle", 1), ("Stable — 2 Cycles", 2), ("Stable — 4 Cycles", 4)], selected: settings.cycles)
        addSettingMenu(to: scopeMenu, title: "Trigger Source", key: "ScopeTrigger", values: [("Same as Channel", 0)] + channels, selected: settings.scopeTrigger)
        addSettingMenu(to: scopeMenu, title: "Capture Length", key: "ScopeDuration", values: [10, 20, 50, 100].map { ("\($0) ms", $0) }, selected: settings.scopeDuration)
        addSettingMenu(to: scopeMenu, title: "Layout", key: "ScopeStacked", values: [("Overlaid", 0), ("Stacked", 1)], selected: settings.scopeStacked)
        addSettingMenu(to: scopeMenu, title: "Persistence", key: "ScopePersistence", values: [("Off", 0), ("Short", 50), ("Medium", 75), ("Long", 90)], selected: settings.scopePersistence)
        addSettingMenu(to: scopeMenu, title: "Normalization", key: "NormalizeScope", values: normalization, selected: settings.normalizeScope ? 1 : 0)
        addGroup(scopeMenu, to: viewMenu)

        let spectrogramMenu = NSMenu(title: "Spectrogram")
        addSettingMenu(to: spectrogramMenu, title: "Reassignment", key: "SpectrogramReassign", values: [("On — Sharpened", 1), ("Off — Classic FFT", 0)], selected: settings.spectrogramReassign)
        addSettingMenu(to: spectrogramMenu, title: "FFT Size", key: "SpectrogramFFT", values: [1024, 2048, 4096, 8192, 16384].map { ("\($0)", $0) }, selected: settings.spectrogramFFT)
        addSettingMenu(to: spectrogramMenu, title: "Hop (Scroll Speed)", key: "SpectrogramHop", values: [4, 6, 8, 16, 32, 64, 128].map { ("FFT ÷ \($0)\($0 == 4 ? " — Slowest" : $0 == 128 ? " — Fastest" : "")", $0) }, selected: settings.spectrogramHop)
        addSettingMenu(to: spectrogramMenu, title: "Window", key: "SpectrogramWindow", values: [("Rectangular", 0), ("Hann", 1), ("Hamming", 2), ("Blackman", 3), ("Blackman-Harris", 4)], selected: settings.spectrogramWindow)
        addSettingMenu(to: spectrogramMenu, title: "Zero Padding", key: "SpectrogramZeroPad", values: [("Off", 1), ("2×", 2), ("4×", 4), ("8×", 8)], selected: settings.spectrogramZeroPad)
        addSettingMenu(to: spectrogramMenu, title: "Frequency Scale", key: "SpectrogramScale", values: [("Linear", 0), ("Logarithmic", 1), ("ERB", 2)], selected: settings.spectrogramScale)
        addSettingMenu(to: spectrogramMenu, title: "Floor", key: "SpectrogramFloor", values: [-60, -80, -100, -120, -140].map { ("−\(-$0) dB", $0) }, selected: settings.spectrogramFloor)
        addSettingMenu(to: spectrogramMenu, title: "Spectral Tilt", key: "SpectrogramTilt", values: [("−3 dB/oct", -30), ("Off", 0), ("+1.5 dB/oct", 15), ("+3 dB/oct", 30), ("+4.5 dB/oct", 45), ("+6 dB/oct", 60)], selected: settings.spectrogramTilt)
        addSettingMenu(to: spectrogramMenu, title: "Orientation", key: "SpectrogramOrientation", values: [("Scroll Left", 0), ("Waterfall Down", 1), ("Waterfall Up", 2)], selected: settings.spectrogramOrientation)
        addSettingMenu(to: spectrogramMenu, title: "Palette", key: "SpectrogramPalette", values: [("Glass", 0), ("Heat", 1)], selected: settings.spectrogramPalette)
        addGroup(spectrogramMenu, to: viewMenu)

        let waveformMenu = NSMenu(title: "Waveform")
        addSettingMenu(to: waveformMenu, title: "Channel", key: "WaveChannel1", values: channels, selected: settings.waveChannel1)
        addSettingMenu(to: waveformMenu, title: "Second Channel", key: "WaveChannel2", values: [("None", 0)] + channels, selected: settings.waveChannel2)
        addSettingMenu(to: waveformMenu, title: "History", key: "WaveSpeed", values: [("2.56 Seconds", 400), ("5.12 Seconds", 200), ("10.24 Seconds", 100)], selected: settings.waveSpeed)
        addSettingMenu(to: waveformMenu, title: "RMS Overlay", key: "WaveRMS", values: [("Off", 0), ("Fast — 50 ms", 1), ("Slow — 370 ms", 2)], selected: settings.waveRMS)
        addSettingMenu(to: waveformMenu, title: "Normalization", key: "NormalizeWaveform", values: normalization, selected: settings.normalizeWaveform ? 1 : 0)
        addGroup(waveformMenu, to: viewMenu)

        let stereoMenu = NSMenu(title: "Stereometer")
        addSettingMenu(to: stereoMenu, title: "Mode", key: "StereoMode", values: [("Lissajous", 0), ("Dot Cloud", 1)], selected: settings.stereoMode)
        addSettingMenu(to: stereoMenu, title: "Scale", key: "StereoScale", values: [("Linear", 0), ("Scaled — Quiet Detail", 1)], selected: settings.stereoScale)
        addSettingMenu(to: stereoMenu, title: "Rotation", key: "StereoRotation", values: [("Mid Vertical", -1), ("Left / Right Axes", 0), ("Mid Horizontal", 1)], selected: settings.stereoRotation)
        addSettingMenu(to: stereoMenu, title: "Left on Left", key: "StereoFlip", values: [("On", 1), ("Off", 0)], selected: settings.stereoFlip)
        addSettingMenu(to: stereoMenu, title: "Correlation", key: "StereoCorrelation", values: [("Off", 0), ("Full Band", 1), ("Low / Mid / High", 2)], selected: settings.stereoCorrelation)
        addSettingMenu(to: stereoMenu, title: "Normalization", key: "NormalizeStereo", values: normalization, selected: settings.normalizeStereo ? 1 : 0)
        addGroup(stereoMenu, to: viewMenu)

        let loudnessMenu = NSMenu(title: "Loudness")
        addSettingMenu(to: loudnessMenu, title: "RMS", key: "LoudnessRMS", values: [("Fast — 300 ms", 0), ("Slow — 1 s", 1)], selected: settings.loudnessRMS)
        addSettingMenu(to: loudnessMenu, title: "Peak Hold", key: "LoudnessPeakHold", values: [("Off", 0), ("3 Seconds", 3), ("10 Seconds", 10), ("Until Clicked", -1)], selected: settings.loudnessPeakHold)
        addGroup(loudnessMenu, to: viewMenu)
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

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = MeterSettingsWindow(controlsMenu: viewMenu, meters: meters) { [weak self] in
                guard let self else { return }
                self.meters.cancelInteraction()
                UserDefaults.standard.set(self.meters.moduleOrder, forKey: "MeterOrder")
                self.meterContainer.needsLayout = true
                self.meters.needsDisplay = true
            }
        }
        settingsWindow?.refresh()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Audioglass",
            .credits: NSAttributedString(string: "Native macOS glass audio meters.\nDSP adapted from OpenMeters 1.15.2 by Maika Namuo.\nGPL-3.0-or-later; source attribution and license are included in the app bundle.\nSource: https://github.com/cillianpower/audioglass")
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

    private func addGroup(_ menu: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
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
        if key.hasPrefix("Normalize") { UserDefaults.standard.set(sender.tag != 0, forKey: key) }
        else { UserDefaults.standard.set(sender.tag, forKey: key) }
        meters.resetNormalization()
        meters.cancelInteraction()
        settings = MeterSettings()
        applyFrameRate()
        meters.settings = settings
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        settingsWindow?.refresh()
        meters.needsDisplay = true
    }

    @objc private func resetAnalysis(_ sender: NSMenuItem) {
        selectSource(source)
    }

    @objc private func resetSectionSizes(_ sender: NSMenuItem) { meters.resetSectionSizes() }

    @objc private func toggleMeter(_ sender: NSMenuItem) {
        meters.cancelInteraction()
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
        meters.headerChanged?()
        settingsWindow?.refresh()
        meters.needsDisplay = true
    }

    @objc private func changeLayout(_ sender: NSMenuItem) {
        meters.cancelInteraction()
        meterContainer?.needsLayout = true
        meters.arrangement = sender.tag
        UserDefaults.standard.set(sender.tag, forKey: "StripLayoutMode")
        sender.menu?.items.filter { $0.action == #selector(changeLayout(_:)) }.forEach { $0.state = $0 === sender ? .on : .off }
        settingsWindow?.refresh()
        meters.needsDisplay = true
    }

    @objc private func changeSmoothing(_ sender: NSMenuItem) {
        smoothing = [Float(0), 0.25, 0.65, 0.9, -1][sender.tag]
        UserDefaults.standard.set(Double(smoothing), forKey: "SpectrumSmoothing")
        meters.smoothingLabel = ["OFF", "LIGHT", "MEDIUM", "HIGH", "PEAK HOLD"][sender.tag]
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        settingsWindow?.refresh()
        meters.needsDisplay = true
    }
}

@MainActor
final class MeterView: NSView {
    var headerChanged: (() -> Void)?
    var sourceLabel = "STOPPED · SELECT AN AUDIO SOURCE" { didSet { headerChanged?() } }
    var settings = MeterSettings()
    static let meterNames = ["SPECTRUM", "OSCILLOSCOPE", "SPECTROGRAM", "WAVEFORM", "STEREOMETER", "LOUDNESS"]
    var visibleMeters: [Int] = {
        let saved = (UserDefaults.standard.array(forKey: "VisibleMeters") as? [Int] ?? Array(0..<6)).filter { (0..<6).contains($0) }
        return saved.isEmpty ? Array(0..<6) : Array(Set(saved)).sorted()
    }()
    let spectrogramView = SpectrogramView()
    /// Updated when the spectrogram panel is drawn; read by the analysis tick.
    private(set) var spectrogramGeometry = SpectrogramGeometry()
    var layoutColumns = 6
    var layoutHorizontal = true
    var arrangement = UserDefaults.standard.integer(forKey: "StripLayoutMode")
    var smoothingLabel = "OFF" { didSet { headerChanged?() } }
    var frameData = AnalysisFrame(frequencies: [], levels: [], waveform: []) {
        didSet {
            if settings.scopePersistence > 0, !oldValue.waveform.isEmpty {
                scopeTrails.insert((oldValue.waveform, oldValue.waveform2), at: 0)
                if scopeTrails.count > 24 { scopeTrails.removeLast() }
            } else if settings.scopePersistence == 0 { scopeTrails.removeAll() }
            updatePeakHold()
            hoverOverlay.needsDisplay = true
            headerChanged?()
        }
    }
    /// Previous scope traces, newest first, for persistence.
    private var scopeTrails: [([Float], [Float])] = []
    private(set) var heldPeaks: [Float] = [-120, -120]
    private var heldTimes: [CFTimeInterval] = [0, 0]
    private var clipTime: CFTimeInterval?
    var clipActive: Bool {
        guard let clipTime else { return false }
        return settings.loudnessPeakHold == -1 || CACurrentMediaTime() - clipTime < max(3, Double(settings.loudnessPeakHold))
    }

    private func updatePeakHold() {
        let metrics = frameData.metrics
        guard metrics.count == AnalysisFrame.metricCount else { return }
        let now = CACurrentMediaTime()
        let hold = settings.loudnessPeakHold
        for channel in 0..<2 {
            let peak = metrics[12 + channel]
            if hold == 0 || peak >= heldPeaks[channel] || (hold > 0 && now - heldTimes[channel] > Double(hold)) {
                heldPeaks[channel] = max(peak, metrics[4 + channel])
                heldTimes[channel] = now
            }
        }
        // Inter-sample (true) peaks above full scale.
        if max(metrics[12], metrics[13]) > 0 { clipTime = now }
    }

    func resetPeakHold() {
        heldPeaks = [-120, -120]
        heldTimes = [0, 0]
        clipTime = nil
        headerChanged?()
    }
    var moduleOrder: [Int] = {
        let saved = UserDefaults.standard.array(forKey: "MeterOrder") as? [Int] ?? Array(0..<5)
        var order: [Int] = []
        for meter in saved + Array(0..<5) where (0..<5).contains(meter) && !order.contains(meter) { order.append(meter) }
        return order
    }()
    var displayMeters: [Int] { moduleOrder.filter { visibleMeters.contains($0) } }
    private var scopeNormalization = DisplayNormalization()
    private var waveformNormalization = DisplayNormalization()
    private var stereoNormalization = DisplayNormalization()
    private var lastNormalizationTime: CFTimeInterval?
    private var scopeGain: CGFloat { settings.normalizeScope ? scopeNormalization.gain : 1 }
    private var waveformGain: CGFloat { settings.normalizeWaveform ? waveformNormalization.gain : 1 }
    private var stereoGain: CGFloat { settings.normalizeStereo ? stereoNormalization.gain : 1 }

    func resetNormalization() {
        scopeNormalization = DisplayNormalization()
        waveformNormalization = DisplayNormalization()
        stereoNormalization = DisplayNormalization()
        lastNormalizationTime = nil
    }

    func advanceNormalization(at time: CFTimeInterval) {
        let elapsed = min(0.1, max(0, time - (lastNormalizationTime ?? time)))
        lastNormalizationTime = time
        if settings.normalizeScope {
            let peak = (frameData.waveform + frameData.waveform2).reduce(Float.zero) { max($0, abs($1)) }
            scopeNormalization.update(peak: peak, elapsed: elapsed)
        }
        if settings.normalizeWaveform {
            // One gain across the whole history and both channels preserves balance.
            var peak: Float = 0
            for (index, value) in frameData.history.enumerated() where index % AnalysisFrame.waveStride < 4 {
                peak = max(peak, abs(value))
            }
            waveformNormalization.update(peak: peak, elapsed: elapsed)
        }
        if settings.normalizeStereo {
            var peak: Float = 0
            for index in stride(from: 0, to: max(0, frameData.stereo.count - 1), by: 2) {
                let left = frameData.stereo[index]
                let right = frameData.stereo[index + 1]
                peak = max(peak, hypot(left, right))
            }
            stereoNormalization.update(peak: peak, elapsed: elapsed)
        }
    }

    private var frozenSpectrum: AnalysisFrame?
    private var spectrumFrame: AnalysisFrame { frozenSpectrum ?? frameData }
    private var horizontalWeights = MeterView.loadWeights("HorizontalMeterWeights")
    private var verticalWeights = MeterView.loadWeights("VerticalMeterWeights")
    private var resizeDrag: (index: Int, start: CGFloat, first: CGFloat, second: CGFloat)?
    private var horizontal: Bool { layoutHorizontal }
    private var minimumExtent: CGFloat { horizontal ? 150 : 110 }
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
        let point = convert(event.locationInWindow, from: nil)
        if !horizontal && point.y < 24 && !event.modifierFlags.contains(.shift) {
            window?.performDrag(with: event)
            return
        }
        if event.modifierFlags.contains(.shift), let index = divider(at: point) {
            let panels = panelRects()
            let first = horizontal ? panels[index].width : panels[index].height
            let second = horizontal ? panels[index + 1].width : panels[index + 1].height
            resizeDrag = (index, horizontal ? point.x : point.y, first, second)
        } else if let index = displayMeters.firstIndex(of: 0), panelRects()[index].contains(point) {
            frozenSpectrum = frameData
            needsDisplay = true
        }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        updateResizeCursor(event)
        hoverOverlay.needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        if resizeDrag == nil { NSCursor.arrow.set() }
        hoverOverlay.needsDisplay = true
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    private static func loadWeights(_ key: String) -> [CGFloat] {
        guard let saved = UserDefaults.standard.array(forKey: key) as? [Double],
              saved.count == meterNames.count, saved.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return Array(repeating: 1, count: meterNames.count)
        }
        return saved.map { CGFloat($0) }
    }

    private func panelRects() -> [NSRect] {
        let area = bounds.insetBy(dx: 8, dy: horizontal ? 3 : 7)
        guard !displayMeters.isEmpty else { return [] }
        let weights = horizontal ? horizontalWeights : verticalWeights
        let total = displayMeters.reduce(CGFloat.zero) { $0 + weights[$1] }
        let available = (horizontal ? area.width : area.height) - CGFloat(displayMeters.count - 1) * 8
        let minimum = min(minimumExtent, max(0, available / CGFloat(displayMeters.count)))
        let extra = max(0, available - minimum * CGFloat(displayMeters.count))
        var offset = horizontal ? area.minX : area.minY
        return displayMeters.map { meter in
            let fraction = total > 0 ? weights[meter] / total : 1 / CGFloat(displayMeters.count)
            let extent = minimum + extra * fraction
            let rect = horizontal
                ? NSRect(x: offset, y: area.minY, width: extent, height: area.height)
                : NSRect(x: area.minX, y: offset, width: area.width, height: extent)
            offset += extent + 8
            return rect
        }
    }

    private func divider(at point: NSPoint) -> Int? {
        let panels = panelRects()
        for index in 0..<max(0, panels.count - 1) {
            let rect = panels[index]
            let hit = horizontal
                ? NSRect(x: rect.maxX - 2, y: rect.minY, width: 12, height: rect.height)
                : NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 12)
            if hit.contains(point) { return index }
        }
        return nil
    }

    private func updateResizeCursor(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if resizeDrag != nil || (event.modifierFlags.contains(.shift) && divider(at: point) != nil) {
            (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        } else { NSCursor.arrow.set() }
    }

    override func flagsChanged(with event: NSEvent) {
        updateResizeCursor(event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
        guard let drag = resizeDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = (horizontal ? point.x : point.y) - drag.start
        let first = max(minimumExtent, min(drag.first + drag.second - minimumExtent, drag.first + delta))
        let second = drag.first + drag.second - first
        let weights = horizontal ? horizontalWeights : verticalWeights
        let total = displayMeters.reduce(CGFloat.zero) { $0 + weights[$1] }
        let panels = panelRects()
        let extra = panels.reduce(CGFloat.zero) { $0 + max(0, (horizontal ? $1.width : $1.height) - minimumExtent) }
        guard extra > 0 else { return }
        // Preserve the weight scale, including sizes of temporarily hidden meters.
        let scale = (total > 0 ? total : 1) / extra
        var updated = weights
        updated[displayMeters[drag.index]] = max(0, first - minimumExtent) * scale
        updated[displayMeters[drag.index + 1]] = max(0, second - minimumExtent) * scale
        if horizontal { horizontalWeights = updated } else { verticalWeights = updated }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        cancelInteraction()
        mouseMoved(with: event)
    }

    func cancelInteraction() {
        if resizeDrag != nil {
            UserDefaults.standard.set(horizontalWeights.map { Double($0) }, forKey: "HorizontalMeterWeights")
            UserDefaults.standard.set(verticalWeights.map { Double($0) }, forKey: "VerticalMeterWeights")
        }
        frozenSpectrum = nil
        resizeDrag = nil
        NSCursor.arrow.set()
        needsDisplay = true
        hoverOverlay.needsDisplay = true
    }

    func resetSectionSizes() {
        cancelInteraction()
        horizontalWeights = Array(repeating: 1, count: Self.meterNames.count)
        verticalWeights = horizontalWeights
        UserDefaults.standard.removeObject(forKey: "HorizontalMeterWeights")
        UserDefaults.standard.removeObject(forKey: "VerticalMeterWeights")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Shift-drag between sections to resize. Click and hold the spectrum to freeze it."
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
        let area = bounds.insetBy(dx: 8, dy: horizontal ? 3 : 7)
        guard area.width > 0, area.height > 40 else { return }
        let rects = panelRects()
        graphs.removeAll(keepingCapacity: true)
        spectrogramView.isHidden = !visibleMeters.contains(2)
        for (position, meter) in displayMeters.enumerated() {
            let rect = rects[position]
            panel(meter, rect: rect) { graph in
                graphs[meter] = graph
                switch meter {
                case 0: spectrum(in: graph)
                case 1: scope(in: graph)
                case 2: spectrogram(in: graph)
                case 3: history(in: graph)
                case 4: stereo(in: graph)
                default: loudness(in: graph)
                }
            }
        }
        if NSEvent.modifierFlags.contains(.shift) || resizeDrag != nil {
            NSColor.white.withAlphaComponent(0.25).setStroke()
            let dividers = NSBezierPath()
            dividers.lineWidth = 1
            for rect in rects.dropLast() {
                if horizontal {
                    dividers.move(to: NSPoint(x: rect.maxX + 4, y: rect.minY))
                    dividers.line(to: NSPoint(x: rect.maxX + 4, y: rect.maxY))
                } else {
                    dividers.move(to: NSPoint(x: rect.minX, y: rect.maxY + 4))
                    dividers.line(to: NSPoint(x: rect.maxX, y: rect.maxY + 4))
                }
            }
            dividers.stroke()
        }
        hoverOverlay.needsDisplay = true
    }

    private func meterTitle(_ meter: Int) -> String {
        let normalized = (meter == 1 && settings.normalizeScope) || (meter == 3 && settings.normalizeWaveform) || (meter == 4 && settings.normalizeStereo)
        return Self.meterNames[meter] + (meter == 0 && frozenSpectrum != nil ? " · HELD" : normalized ? " · NORM" : "")
    }

    private func panel(_ meter: Int, rect: NSRect, draw: (NSRect) -> Void) {
        if !horizontal {
            text(meterTitle(meter), at: NSPoint(x: rect.minX + 4, y: rect.minY + 2), size: 9, color: .white.withAlphaComponent(0.55))
        }
        // Only the spectrum needs a footer for its frequency axis in the strip.
        let top: CGFloat = horizontal ? 0 : 20
        let bottom: CGFloat = horizontal && meter != 0 ? 0 : 16
        let graph = NSRect(x: rect.minX + 4, y: rect.minY + top, width: rect.width - 8, height: rect.height - top - bottom)
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
        if meter == 0 {
            for (frequency, label) in spectrumTicks {
                let x = graph.minX + graph.width * spectrumPosition(frequency)
                text(label, at: NSPoint(x: x - 7, y: graph.maxY + 3), size: 8, color: .white.withAlphaComponent(0.4))
            }
        }
    }

    /// Horizontal position (0...1) of a frequency on the spectrum's axis.
    private func spectrumPosition(_ hz: Double) -> CGFloat {
        let maximum = FrequencyAxis.scaled(Double(spectrumFrame.frequencies.last ?? 24000), scale: settings.spectrumScale)
        return CGFloat(FrequencyAxis.scaled(max(0, hz), scale: settings.spectrumScale) / max(maximum, 1e-9))
    }

    private var spectrumTicks: [(Double, String)] {
        settings.spectrumScale == 0 ? [(5000, "5k"), (10000, "10k"), (15000, "15k"), (20000, "20k")]
            : [(100, "100"), (1000, "1k"), (10000, "10k")]
    }

    private func spectrumLevel(_ level: Float) -> CGFloat {
        CGFloat(max(0, min(1, (level - Float(settings.floor)) / Float(-settings.floor))))
    }

    private func spectrumTrace(_ levels: [Float], in rect: NSRect, alpha: CGFloat) {
        let frequencies = spectrumFrame.frequencies
        guard !levels.isEmpty, levels.count == frequencies.count else { return }
        var trace = PixelTrace(scale: window?.backingScaleFactor ?? 2)
        let path = trace.path
        for (frequency, level) in zip(frequencies, levels) {
            trace.append(NSPoint(x: rect.minX + rect.width * spectrumPosition(Double(frequency)),
                                 y: rect.maxY - rect.height * spectrumLevel(level)))
        }
        trace.finish()
        NSColor.white.withAlphaComponent(alpha).setStroke()
        path.lineWidth = 1
        path.lineJoinStyle = .miter
        path.stroke()
    }

    private func spectrum(in rect: NSRect) {
        for (frequency, _) in spectrumTicks {
            let x = rect.minX + rect.width * spectrumPosition(frequency)
            NSColor.white.withAlphaComponent(0.08).setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 0.5
            grid.move(to: NSPoint(x: x, y: rect.minY))
            grid.line(to: NSPoint(x: x, y: rect.maxY))
            grid.stroke()
        }
        spectrumTrace(spectrumFrame.secondaryLevels, in: rect, alpha: 0.42)
        spectrumTrace(spectrumFrame.levels, in: rect, alpha: 0.92)
        guard settings.spectrumPeakLabel == 1 else { return }
        let frame = spectrumFrame
        guard let peak = frame.levels.indices.filter({ frame.frequencies[$0] >= 20 })
            .max(by: { frame.levels[$0] < frame.levels[$1] }), frame.levels[peak] > Float(settings.floor) else { return }
        let point = NSPoint(x: rect.minX + rect.width * spectrumPosition(Double(frame.frequencies[peak])),
                            y: rect.maxY - rect.height * spectrumLevel(frame.levels[peak]))
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
        let label = frequencyLabel(Double(frame.frequencies[peak])) + String(format: " · %.1f dB", frame.levels[peak])
        let width = CGFloat(label.count) * 5.5
        let x = min(max(rect.minX + 2, point.x - width / 2), rect.maxX - width)
        text(label, at: NSPoint(x: x, y: max(rect.minY + 1, point.y - 15)), size: 8, color: .white.withAlphaComponent(0.85))
    }

    /// Lanes for the oscilloscope's traces: (samples, centre, half height, alpha).
    private func scopeLanes(_ first: [Float], _ second: [Float], in rect: NSRect) -> [([Float], CGFloat, CGFloat, CGFloat)] {
        guard !second.isEmpty else { return [(first, rect.midY, rect.height * 0.5, 0.92)] }
        if settings.scopeStacked == 1 {
            return [(first, rect.minY + rect.height * 0.25, rect.height * 0.25, 0.92),
                    (second, rect.minY + rect.height * 0.75, rect.height * 0.25, 0.7)]
        }
        return [(second, rect.midY, rect.height * 0.5, 0.45), (first, rect.midY, rect.height * 0.5, 0.92)]
    }

    private func scopeTrace(_ samples: [Float], center: CGFloat, half: CGFloat, alpha: CGFloat, in rect: NSRect) {
        guard samples.count > 1 else { return }
        var trace = PixelTrace(scale: window?.backingScaleFactor ?? 2)
        let path = trace.path
        for (i, sample) in samples.enumerated() {
            let x = Double(i) / Double(samples.count - 1)
            trace.append(NSPoint(x: rect.minX + rect.width * x, y: center - CGFloat(sample) * scopeGain * half))
        }
        trace.finish()
        NSColor.white.withAlphaComponent(alpha).setStroke()
        path.lineWidth = 1
        path.lineJoinStyle = .miter
        path.stroke()
    }

    private func scope(in rect: NSRect) {
        if settings.scopeStacked == 1 && !frameData.waveform2.isEmpty {
            NSColor.white.withAlphaComponent(0.1).setStroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: rect.minX, y: rect.midY))
            divider.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            divider.stroke()
        }
        // Older traces fade geometrically with the persistence factor.
        let persistence = CGFloat(settings.scopePersistence) / 100
        for (age, trail) in scopeTrails.enumerated().reversed() {
            let fade = pow(persistence, CGFloat(age + 1))
            guard fade > 0.04 else { continue }
            for lane in scopeLanes(trail.0, trail.1, in: rect) {
                scopeTrace(lane.0, center: lane.1, half: lane.2, alpha: lane.3 * fade * 0.6, in: rect)
            }
        }
        for lane in scopeLanes(frameData.waveform, frameData.waveform2, in: rect) {
            scopeTrace(lane.0, center: lane.1, half: lane.2, alpha: lane.3, in: rect)
        }
    }

    private func spectrogram(in rect: NSRect) {
        spectrogramView.frame = rect
        let scale = window?.backingScaleFactor ?? 2
        let scrollsLeft = settings.spectrogramOrientation == 0
        let time = scrollsLeft ? rect.width : rect.height
        let frequency = scrollsLeft ? rect.height : rect.width
        // One column per point, as upstream; rows are physical pixels.
        spectrogramGeometry = SpectrogramGeometry(columns: max(16, min(4096, Int(time.rounded()))),
            rows: max(16, min(2048, Int((frequency * scale).rounded()))), rowSpan: max(1, Int(scale.rounded())))
        spectrogramView.style = SpectrogramStyle(floor: Float(settings.spectrogramFloor),
            tilt: Float(settings.spectrogramTilt) / 10, scale: settings.spectrogramScale,
            orientation: settings.spectrogramOrientation, palette: settings.spectrogramPalette,
            sampleRate: frameData.timing[0])
    }

    private static let shortChannelNames = ["", "M", "S", "L", "R"]

    /// Waveform lanes: (centre, half height) for each configured channel.
    private func waveformLanes(in rect: NSRect) -> [(CGFloat, CGFloat)] {
        settings.waveChannel2 == 0 ? [(rect.midY, rect.height * 0.46)]
            : [(rect.minY + rect.height * 0.25, rect.height * 0.23), (rect.minY + rect.height * 0.75, rect.height * 0.23)]
    }

    private func history(in rect: NSRect) {
        let stride = AnalysisFrame.waveStride
        let count = frameData.history.count / stride
        guard count > 0 else { return }
        let rms = settings.waveRMS != 0
        for (lane, (middle, half)) in waveformLanes(in: rect).enumerated() {
            let scale = half * waveformGain
            let path = NSBezierPath()
            let envelope = NSBezierPath()
            for column in 0..<count {
                let base = column * stride
                let x = rect.maxX - CGFloat(count - column) / 1024 * rect.width
                let low = CGFloat(frameData.history[base + lane * 2])
                let high = CGFloat(frameData.history[base + lane * 2 + 1])
                path.move(to: NSPoint(x: x, y: middle - high * scale))
                path.line(to: NSPoint(x: x, y: middle - low * scale))
                if rms {
                    let level = CGFloat(frameData.history[base + 4 + lane])
                    envelope.move(to: NSPoint(x: x, y: middle - level * scale))
                    envelope.line(to: NSPoint(x: x, y: middle + level * scale))
                }
            }
            NSColor.white.withAlphaComponent(rms ? 0.35 : lane == 0 ? 0.9 : 0.55).setStroke()
            path.lineWidth = 0.7
            path.stroke()
            if rms {
                NSColor.white.withAlphaComponent(lane == 0 ? 0.95 : 0.75).setStroke()
                envelope.lineWidth = 0.7
                envelope.stroke()
            }
        }
        let names = [settings.waveChannel1, settings.waveChannel2].filter { $0 != 0 }.map { Self.shortChannelNames[$0] }
        text(String(format: "%@ · %.2f s", names.joined(separator: " / "), 1024.0 / Double(settings.waveSpeed)) + (rms ? " · RMS" : ""),
             at: NSPoint(x: rect.minX + 3, y: rect.minY + 2), size: 8, color: .white.withAlphaComponent(0.45))
    }

    // Upstream OpenMeters stereometer projection (render.rs), drawn with AppKit.
    private func stereoUnit(_ left: CGFloat, _ right: CGFloat) -> NSPoint {
        let (l, r) = settings.stereoFlip == 1 ? (right, left) : (left, right)
        let angle = CGFloat(settings.stereoRotation) * .pi / 4
        let x = l * cos(angle) + r * sin(angle)
        let y = l * sin(angle) - r * cos(angle)
        guard settings.stereoScale == 1 else { return NSPoint(x: x, y: y) }
        // radius = min((0.66834 * length)^0.3, 1), expanding quiet material.
        let squared = x * x + y * y
        guard squared > CGFloat(Float.ulpOfOne * Float.ulpOfOne) else { return .zero }
        let scale = squared < 2.2387474 ? 0.8861337 * pow(squared, -0.35) : 1 / sqrt(squared)
        return NSPoint(x: x * scale, y: y * scale)
    }

    private func stereo(in rect: NSRect) {
        let footer: CGFloat = settings.stereoCorrelation == 0 ? 0 : 18
        let radius = min(rect.width, rect.height - footer) * 0.48
        guard radius > 0 else { return }
        let center = NSPoint(x: rect.midX, y: rect.minY + (rect.height - footer) / 2)
        let scaled = settings.stereoScale == 1
        NSColor.white.withAlphaComponent(0.1).setStroke()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).stroke()
        if scaled {
            // −48, −24 and −12 dBFS guides.
            NSColor.white.withAlphaComponent(0.05).setStroke()
            for level in [0.0039810717, 0.06309573, 0.25118864] as [CGFloat] {
                let ring = radius * min(1, pow(0.66834 * level, 0.3))
                NSBezierPath(ovalIn: NSRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)).stroke()
            }
        }
        for (axis, alpha) in [((1.0, 1.0), 0.1), ((1.0, 0.0), 0.05), ((0.0, 1.0), 0.05)] as [((CGFloat, CGFloat), CGFloat)] {
            let end = stereoUnit(axis.0, axis.1)
            let length = max(hypot(end.x, end.y), 1e-6)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: center.x - end.x / length * radius, y: center.y - end.y / length * radius))
            line.line(to: NSPoint(x: center.x + end.x / length * radius, y: center.y + end.y / length * radius))
            NSColor.white.withAlphaComponent(alpha).setStroke()
            line.stroke()
        }
        // The scaled view is already level-compressed, so display gain applies to linear only.
        let gain = scaled ? 1 : stereoGain
        let path = NSBezierPath()
        for index in Swift.stride(from: 0, to: max(0, frameData.stereo.count - 1), by: 2) {
            let unit = stereoUnit(CGFloat(frameData.stereo[index]) * gain, CGFloat(frameData.stereo[index + 1]) * gain)
            let point = NSPoint(x: center.x + unit.x * radius, y: center.y + unit.y * radius)
            if settings.stereoMode == 1 { path.appendRect(NSRect(x: point.x - 0.6, y: point.y - 0.6, width: 1.2, height: 1.2)) }
            else if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        if settings.stereoMode == 1 {
            NSColor.white.withAlphaComponent(0.55).setFill()
            path.fill()
        } else {
            NSColor.white.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 0.7
            path.stroke()
        }
        let metrics = frameData.metrics
        guard settings.stereoCorrelation != 0, metrics.count == AnalysisFrame.metricCount else { return }
        let y = rect.maxY - 13
        if settings.stereoCorrelation == 2 {
            text(String(format: "LO %+.2f  MID %+.2f  HI %+.2f", metrics[7], metrics[8], metrics[9]),
                 at: NSPoint(x: rect.minX + 2, y: y), size: 9, color: .white.withAlphaComponent(0.7), width: rect.width - 4)
            return
        }
        text(String(format: "CORR %+.2f", metrics[6]), at: NSPoint(x: rect.minX + 2, y: y), size: 9, color: .white.withAlphaComponent(0.7))
        let bar = NSRect(x: rect.minX + 76, y: y + 6, width: rect.width - 80, height: 1)
        guard bar.width > 20 else { return }
        NSColor.white.withAlphaComponent(0.15).setFill()
        bar.fill()
        NSRect(x: bar.midX - 0.5, y: bar.minY - 3, width: 1, height: 7).fill()
        let marker = bar.minX + bar.width * CGFloat((max(-1, min(1, metrics[6])) + 1) / 2)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSRect(x: marker - 1, y: bar.minY - 3, width: 2, height: 7).fill()
    }

    /// Smallest height that shows every loudness line.
    var loudnessMinimumHeight: CGFloat { 4 * 17 + 14 + (settings.loudnessPeakHold != 0 ? 14 : 0) }

    private var loudnessRows: [(label: String, value: Float, unit: String)] {
        let metrics = frameData.metrics
        let rms = settings.loudnessRMS == 1 ? (metrics[10], metrics[11]) : (metrics[2], metrics[3])
        return [("M", metrics[0], "LUFS"), ("S", metrics[1], "LUFS"), ("RMS L", rms.0, "dBFS"), ("RMS R", rms.1, "dBFS")]
    }

    private var peakLines: [(String, CGFloat)] {
        let peak = { (value: Float) in value > -99.8 ? String(format: "%.1f", value) : "−∞" }
        let metrics = frameData.metrics
        var lines = [("TP \(peak(metrics[4])) / \(peak(metrics[5])) dBTP", CGFloat(0.6))]
        if settings.loudnessPeakHold != 0 { lines.append(("MAX \(peak(heldPeaks[0])) / \(peak(heldPeaks[1])) dBTP", 0.85)) }
        return lines
    }

    /// One reading with a bar beneath; the track spans −60 to 0 dB so headroom reads as scale.
    private func loudnessRow(_ row: (label: String, value: Float, unit: String), at point: NSPoint, width: CGFloat) {
        let value = row.value.isFinite && row.value > -99.8 ? String(format: "%.1f", row.value) : "−∞"
        text("\(row.label)  \(value) \(row.unit)", at: point, size: 10, color: .white.withAlphaComponent(0.85), width: width)
        let track = NSRect(x: point.x, y: point.y + 14, width: width, height: 2)
        NSColor.white.withAlphaComponent(0.12).setFill()
        track.fill()
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(max(0, min(1, (row.value + 60) / 60))), height: 2).fill()
    }

    /// Stacked readings for the vertical layout's left column.
    func loudness(in rect: NSRect) {
        guard frameData.metrics.count == AnalysisFrame.metricCount else { return }
        let lineHeight = min(24, max(17, (rect.height - 28) / 4))
        for (index, row) in loudnessRows.enumerated() {
            loudnessRow(row, at: NSPoint(x: rect.minX + 2, y: rect.minY + CGFloat(index) * lineHeight), width: rect.width - 2)
        }
        for (index, line) in peakLines.enumerated() {
            text(line.0, at: NSPoint(x: rect.minX + 2, y: rect.minY + lineHeight * 4 + CGFloat(index) * 14), size: 9, color: .white.withAlphaComponent(line.1))
        }
    }

    static func loudnessGridHeight(columns: Int) -> CGFloat { CGFloat(4 / columns) * 20 + 13 }

    /// Readings in a grid for the vertical layout's top block, with peaks on one line beneath.
    func loudnessGrid(in rect: NSRect, columns: Int) {
        guard frameData.metrics.count == AnalysisFrame.metricCount else { return }
        let cell = rect.width / CGFloat(columns)
        for (index, row) in loudnessRows.enumerated() {
            loudnessRow(row, at: NSPoint(x: rect.minX + CGFloat(index % columns) * cell, y: rect.minY + CGFloat(index / columns) * 20),
                        width: max(0, cell - 16))
        }
        var x = rect.minX
        for line in peakLines {
            text(line.0, at: NSPoint(x: x, y: rect.minY + CGFloat(4 / columns) * 20), size: 9, color: .white.withAlphaComponent(line.1))
            x += textWidth(line.0, size: 9) + 16
        }
    }

    func textWidth(_ value: String, size: CGFloat) -> CGFloat {
        (value as NSString).size(withAttributes: [.font: NSFont(name: "Menlo", size: size) ?? NSFont.systemFont(ofSize: size)]).width
    }

    func clipBadge(in badge: NSRect) {
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        text("CLIP", at: NSPoint(x: badge.minX + 4, y: badge.minY), size: 9, color: .black.withAlphaComponent(0.85))
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
              let (meter, rect) = graphs.first(where: { $0.value.contains(point) }) else { return }
        let x = max(0, min(1, (point.x - rect.minX) / rect.width))
        let y = max(0, min(1, (point.y - rect.minY) / rect.height))
        let timing = frameData.timing
        let rate = Double(timing[0])
        var lines: [String] = []
        var marker: NSPoint?
        switch meter {
        case 0:
            let maximum = FrequencyAxis.scaled(Double(spectrumFrame.frequencies.last ?? Float(rate / 2)), scale: settings.spectrumScale)
            let hz = FrequencyAxis.frequency(Double(x) * maximum, scale: settings.spectrumScale)
            if let index = spectrumFrame.frequencies.indices.min(by: {
                abs(Double(spectrumFrame.frequencies[$0]) - hz) < abs(Double(spectrumFrame.frequencies[$1]) - hz)
            }), index < spectrumFrame.levels.count {
                let frequency = Double(spectrumFrame.frequencies[index])
                let level = spectrumFrame.levels[index]
                lines = [frequencyLabel(frequency), String(format: "%.1f dB%@ · %@", level,
                    settings.weighted ? "(A)" : "FS", ["MID", "SIDE", "LEFT", "RIGHT"][settings.channel])]
                if index < spectrumFrame.secondaryLevels.count {
                    lines.append(String(format: "%.1f dB%@ · %@", spectrumFrame.secondaryLevels[index],
                        settings.weighted ? "(A)" : "FS", MeterSettings.channelNames[settings.spectrumSecondary]))
                }
                marker = NSPoint(x: rect.minX + rect.width * spectrumPosition(frequency), y: rect.maxY - rect.height * spectrumLevel(level))
            } else { lines = [frequencyLabel(hz), "Waiting for spectrum"] }
        case 1:
            if frameData.waveform.count > 1 {
                let index = Int((x * CGFloat(frameData.waveform.count - 1)).rounded())
                let stacked = settings.scopeStacked == 1 && !frameData.waveform2.isEmpty
                // Stacked: the hovered lane; overlaid: channel 1 first, then channel 2.
                let second = stacked && y >= 0.5
                let samples = second ? frameData.waveform2 : frameData.waveform
                let sample = samples[min(index, samples.count - 1)]
                let name = MeterSettings.channelNames[second ? settings.scopeChannel2 : settings.scopeChannel]
                lines = [String(format: "%.2f ms · %@", Double(index) / Double(frameData.waveform.count - 1) * Double(timing[1]) * 1000, name),
                    amplitudeLabel(sample)]
                if !stacked, !frameData.waveform2.isEmpty {
                    lines.append(amplitudeLabel(frameData.waveform2[min(index, frameData.waveform2.count - 1)]) + " · " + MeterSettings.channelNames[settings.scopeChannel2])
                }
                lines.append(settings.cycles == 0 ? "Zero-crossing trigger" : timing[2] > 0 ? frequencyLabel(Double(timing[2])) : "No stable pitch · free running")
                let lane = scopeLanes(frameData.waveform, frameData.waveform2, in: rect).first { $0.0 == samples } ?? (samples, rect.midY, rect.height * 0.5, 1)
                marker = NSPoint(x: rect.minX + CGFloat(index) / CGFloat(frameData.waveform.count - 1) * rect.width,
                    y: lane.1 - CGFloat(sample) * scopeGain * lane.2)
            } else { lines = ["Waiting for oscilloscope"] }
        case 2:
            // Matches the shader: time 0 oldest .. 1 newest, frequency 0 lowest .. 1 highest.
            let (time, frequency): (CGFloat, CGFloat) = switch settings.spectrogramOrientation {
            case 1: (1 - y, x)
            case 2: (y, x)
            default: (x, 1 - y)
            }
            let sample = spectrogramView.sample(time: time, frequency: frequency)
            lines = [frequencyLabel(sample.hz), String(format: "%.3f s ago · MID", Double(sample.age) * Double(timing[3]))]
            if let db = sample.db {
                let kind = settings.spectrogramReassign == 1 ? "reassigned pixel" : "FFT bin"
                lines.append(db <= -139.99 ? "≤ −140 dBFS" : String(format: "%.1f dBFS · %@", db, kind))
            } else { lines.append("No history here yet") }
        case 3:
            let stride = AnalysisFrame.waveStride
            let count = frameData.history.count / stride
            let column = Int(x * 1024) - (1024 - count)
            let channel = settings.waveChannel2 != 0 && y >= 0.5 ? 1 : 0
            lines = [String(format: "%.3f s ago · %@", Double(1024 - min(1023, Int(x * 1024))) / Double(settings.waveSpeed),
                MeterSettings.channelNames[channel == 0 ? settings.waveChannel1 : settings.waveChannel2])]
            if column >= 0 && column < count {
                let low = frameData.history[column * stride + channel * 2]
                let high = frameData.history[column * stride + channel * 2 + 1]
                let peak = max(abs(low), abs(high))
                lines.append(String(format: "min %+.3f · max %+.3f", low, high))
                lines.append(peak > 0 ? String(format: "Peak %.1f dBFS", 20 * log10(peak)) : "Peak −∞ dBFS")
                if settings.waveRMS != 0 {
                    let level = frameData.history[column * stride + 4 + channel]
                    lines.append(level > 0 ? String(format: "RMS %.1f dBFS", 20 * log10(level)) : "RMS −∞ dBFS")
                }
            } else { lines.append("No history here yet") }
        default:
            guard horizontal else { return }
        }
        if horizontal { lines.insert(meterTitle(meter), at: 0) }
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
        if meter < 4 { guide.stroke() }
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
            .font: (NSFont(name: "Menlo", size: size) ?? NSFont.systemFont(ofSize: size)),
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
