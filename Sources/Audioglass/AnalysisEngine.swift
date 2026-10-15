import Foundation

struct MeterSettings: Sendable {
    var frameRate = UserDefaults.standard.object(forKey: "FrameRate") as? Int ?? 120
    var channel = UserDefaults.standard.integer(forKey: "AnalysisChannel")
    var fftSize = UserDefaults.standard.object(forKey: "FFTSize") as? Int ?? 16384
    var weighted = UserDefaults.standard.bool(forKey: "AWeighting")
    var floor = UserDefaults.standard.object(forKey: "SpectrumFloor") as? Int ?? -120
    var cycles = UserDefaults.standard.object(forKey: "ScopeCycles") as? Int ?? 2
    var waveSpeed = UserDefaults.standard.object(forKey: "WaveSpeed") as? Int ?? 200
    var normalizeScope = UserDefaults.standard.object(forKey: "NormalizeScope") as? Bool ?? true
    var normalizeWaveform = UserDefaults.standard.object(forKey: "NormalizeWaveform") as? Bool ?? true
    var normalizeStereo = UserDefaults.standard.object(forKey: "NormalizeStereo") as? Bool ?? true
    // Spectrogram defaults follow upstream OpenMeters.
    var spectrogramFFT = UserDefaults.standard.object(forKey: "SpectrogramFFT") as? Int ?? 4096
    var spectrogramHop = UserDefaults.standard.object(forKey: "SpectrogramHop") as? Int ?? 16
    var spectrogramWindow = UserDefaults.standard.object(forKey: "SpectrogramWindow") as? Int ?? 1
    var spectrogramReassign = UserDefaults.standard.object(forKey: "SpectrogramReassign") as? Int ?? 1
    var spectrogramZeroPad = UserDefaults.standard.object(forKey: "SpectrogramZeroPad") as? Int ?? 1
    var spectrogramScale = UserDefaults.standard.object(forKey: "SpectrogramScale") as? Int ?? 1
    var spectrogramFloor = UserDefaults.standard.object(forKey: "SpectrogramFloor") as? Int ?? -120
    /// Tenths of a dB per octave.
    var spectrogramTilt = UserDefaults.standard.object(forKey: "SpectrogramTilt") as? Int ?? 45
    var spectrogramOrientation = UserDefaults.standard.integer(forKey: "SpectrogramOrientation")
    var spectrogramPalette = UserDefaults.standard.integer(forKey: "SpectrogramPalette")
    // Channel codes shared with the bridge: 0 none, 1 mid, 2 side, 3 left, 4 right.
    var spectrumSecondary = UserDefaults.standard.integer(forKey: "SpectrumSecondary")
    var spectrumScale = UserDefaults.standard.object(forKey: "SpectrumScale") as? Int ?? 1
    var spectrumPeakLabel = UserDefaults.standard.integer(forKey: "SpectrumPeakLabel")
    // The scope used to share the spectrum's channel; keep that choice on upgrade.
    var scopeChannel = UserDefaults.standard.object(forKey: "ScopeChannel") as? Int
        ?? [1, 2, 3, 4][max(0, min(3, UserDefaults.standard.integer(forKey: "AnalysisChannel")))]
    var scopeChannel2 = UserDefaults.standard.integer(forKey: "ScopeChannel2")
    var scopeTrigger = UserDefaults.standard.integer(forKey: "ScopeTrigger")
    var scopeDuration = UserDefaults.standard.object(forKey: "ScopeDuration") as? Int ?? 50
    var scopeStacked = UserDefaults.standard.integer(forKey: "ScopeStacked")
    var scopePersistence = UserDefaults.standard.integer(forKey: "ScopePersistence")
    var waveChannel1 = UserDefaults.standard.object(forKey: "WaveChannel1") as? Int ?? 3
    var waveChannel2 = UserDefaults.standard.object(forKey: "WaveChannel2") as? Int ?? 4
    var waveRMS = UserDefaults.standard.integer(forKey: "WaveRMS")
    var stereoMode = UserDefaults.standard.integer(forKey: "StereoMode")
    var stereoScale = UserDefaults.standard.integer(forKey: "StereoScale")
    var stereoRotation = UserDefaults.standard.object(forKey: "StereoRotation") as? Int ?? -1
    var stereoFlip = UserDefaults.standard.object(forKey: "StereoFlip") as? Int ?? 1
    var stereoCorrelation = UserDefaults.standard.object(forKey: "StereoCorrelation") as? Int ?? 1
    var loudnessRMS = UserDefaults.standard.integer(forKey: "LoudnessRMS")
    /// Seconds; 0 off, -1 until clicked.
    var loudnessPeakHold = UserDefaults.standard.integer(forKey: "LoudnessPeakHold")
    init() {
        if ![60, 120].contains(frameRate) { frameRate = 120 }
        if !(0...3).contains(channel) { channel = 0 }
        if ![4096, 8192, 16384, 32768].contains(fftSize) { fftSize = 16384 }
        if ![-60, -90, -120].contains(floor) { floor = -120 }
        if ![0, 1, 2, 4].contains(cycles) { cycles = 2 }
        if ![100, 200, 400].contains(waveSpeed) { waveSpeed = 200 }
        if ![1024, 2048, 4096, 8192, 16384].contains(spectrogramFFT) { spectrogramFFT = 4096 }
        if ![4, 6, 8, 16, 32, 64, 128].contains(spectrogramHop) { spectrogramHop = 16 }
        if !(0...4).contains(spectrogramWindow) { spectrogramWindow = 1 }
        if !(0...1).contains(spectrogramReassign) { spectrogramReassign = 1 }
        if ![1, 2, 4, 8].contains(spectrogramZeroPad) { spectrogramZeroPad = 1 }
        if !(0...2).contains(spectrogramScale) { spectrogramScale = 1 }
        if ![-60, -80, -100, -120, -140].contains(spectrogramFloor) { spectrogramFloor = -120 }
        if ![-30, 0, 15, 30, 45, 60].contains(spectrogramTilt) { spectrogramTilt = 45 }
        if !(0...2).contains(spectrogramOrientation) { spectrogramOrientation = 0 }
        if !(0...1).contains(spectrogramPalette) { spectrogramPalette = 0 }
        if !(0...4).contains(spectrumSecondary) { spectrumSecondary = 0 }
        if !(0...2).contains(spectrumScale) { spectrumScale = 1 }
        if !(0...1).contains(spectrumPeakLabel) { spectrumPeakLabel = 0 }
        if !(1...4).contains(scopeChannel) { scopeChannel = 1 }
        if !(0...4).contains(scopeChannel2) { scopeChannel2 = 0 }
        if !(0...4).contains(scopeTrigger) { scopeTrigger = 0 }
        if ![10, 20, 50, 100].contains(scopeDuration) { scopeDuration = 50 }
        if !(0...1).contains(scopeStacked) { scopeStacked = 0 }
        if ![0, 50, 75, 90].contains(scopePersistence) { scopePersistence = 0 }
        if !(1...4).contains(waveChannel1) { waveChannel1 = 3 }
        if !(0...4).contains(waveChannel2) { waveChannel2 = 4 }
        if !(0...2).contains(waveRMS) { waveRMS = 0 }
        if !(0...1).contains(stereoMode) { stereoMode = 0 }
        if !(0...1).contains(stereoScale) { stereoScale = 0 }
        if !(-1...1).contains(stereoRotation) { stereoRotation = -1 }
        if !(0...1).contains(stereoFlip) { stereoFlip = 1 }
        if !(0...2).contains(stereoCorrelation) { stereoCorrelation = 1 }
        if !(0...1).contains(loudnessRMS) { loudnessRMS = 0 }
        if ![0, 3, 10, -1].contains(loudnessPeakHold) { loudnessPeakHold = 0 }
    }

    static let channelNames = ["NONE", "MID", "SIDE", "LEFT", "RIGHT"]
}

import DSPBridge

struct AnalysisFrame: Sendable {
    let frequencies: [Float]
    let levels: [Float]
    let waveform: [Float]
    var secondaryLevels: [Float] = []
    var waveform2: [Float] = []
    var history: [Float] = []
    var stereo: [Float] = []
    var metrics: [Float] = []
    var spectrogram: SpectrogramDelta?
    var timing: [Float] = [48000, 0, 0, 256.0 / 48000, 0]
    /// Waveform column layout: ch1 min/max, ch2 min/max, ch1/ch2 RMS.
    static let waveStride = 6
    /// M, S, RMS fast L/R, true peak L/R, correlation full/low/mid/high, RMS slow L/R, peak max L/R.
    static let metricCount = 14
}

// The delegate's serial analysis queue owns all access to this handle.
final class AnalysisEngine: @unchecked Sendable {
    private var handle = ag_create()!
    private var pcm = [Float](repeating: 0, count: 8192)
    private var dropped: UInt64 = 0
    private var history = [Float](repeating: 0, count: 1024 * AnalysisFrame.waveStride)
    private var stereo = [Float](repeating: 0, count: 4000)
    private var metrics = [Float](repeating: 0, count: AnalysisFrame.metricCount)
    private var spectrogramValues: [Float] = []
    private var frequencies = [Float](repeating: 0, count: 16385)
    private var levels = [Float](repeating: 0, count: 16385)
    private var secondary = [Float](repeating: 0, count: 16385)
    private var waveform = [Float](repeating: 0, count: 48000)
    private var waveform2 = [Float](repeating: 0, count: 48000)

    deinit { ag_destroy(handle) }

    func reset() {
        ag_destroy(handle)
        handle = ag_create()!
        dropped = 0
    }

    private func configure(_ settings: MeterSettings, _ geometry: SpectrogramGeometry, _ smoothing: Float) {
        ag_configure(handle, Int32(settings.channel), Int32(settings.fftSize), settings.weighted ? 1 : 0,
            Float(settings.floor), Int32(settings.cycles), Float(settings.waveSpeed), smoothing)
        ag_configure_spectrogram(handle, Int32(settings.spectrogramFFT), Int32(settings.spectrogramHop),
            Int32(settings.spectrogramWindow), Int32(settings.spectrogramReassign), Int32(settings.spectrogramZeroPad),
            Int32(settings.spectrogramScale), Int32(geometry.columns), Int32(geometry.rows), Int32(geometry.rowSpan))
        var options = AGMeterOptions(spectrum_secondary: Int32(settings.spectrumSecondary),
            scope_channel: Int32(settings.scopeChannel), scope_channel2: Int32(settings.scopeChannel2),
            scope_trigger: Int32(settings.scopeTrigger), scope_duration_ms: Int32(settings.scopeDuration),
            waveform_channel1: Int32(settings.waveChannel1), waveform_channel2: Int32(settings.waveChannel2),
            waveform_rms: Int32(settings.waveRMS), stereo_bands: settings.stereoCorrelation == 2 ? 1 : 0)
        ag_configure_options(handle, &options)
    }

    func process(input: CaptureInput?, settings: MeterSettings, geometry: SpectrogramGeometry,
                 smoothing: Float) -> AnalysisFrame {
        configure(settings, geometry, smoothing)
        if let input {
            let losses = ag_transport_dropped(input.transport)
            if losses != dropped {
                reset()
                dropped = losses
                configure(settings, geometry, smoothing)
                // Discard pre-gap history; resume with the next available block.
                while ag_transport_read(input.transport, &pcm, 4096) > 0 {}
            }
            // Bound each job, while normally consuming faster than capture.
            for _ in 0..<16 {
                let count = ag_transport_read(input.transport, &pcm, 4096)
                if count == 0 { break }
                ag_ingest(handle, &pcm, Int32(count), input.sampleRate)
            }
        }

        let counts = ag_process(handle, smoothing, &frequencies, &levels, &secondary, 16385, &waveform, &waveform2, 48000)
        var meterCounts: [Int32] = [0, 0]
        ag_read_meters(handle, &history, &stereo, &metrics, &meterCounts)
        var info = [Int64](repeating: 0, count: 6)
        let needed = Int(ag_spectrogram_pending(handle, &info))
        if spectrogramValues.count < needed { spectrogramValues = [Float](repeating: 0, count: needed) }
        ag_spectrogram_read(handle, &spectrogramValues, Int64(spectrogramValues.count), &info)
        let rows = Int(info[2]), count = Int(info[4])
        var timing = [Float](repeating: 0, count: 5)
        ag_read_timing(handle, &timing)
        return AnalysisFrame(
            frequencies: Array(frequencies.prefix(Int(counts.spectrum_count))),
            levels: Array(levels.prefix(Int(counts.spectrum_count))),
            waveform: Array(waveform.prefix(Int(counts.scope_count))),
            secondaryLevels: Array(secondary.prefix(Int(counts.secondary_count))),
            waveform2: Array(waveform2.prefix(Int(counts.scope2_count))),
            history: Array(history.prefix(Int(meterCounts[0]) * AnalysisFrame.waveStride)),
            stereo: Array(stereo.prefix(Int(meterCounts[1]) * 2)),
            metrics: metrics,
            spectrogram: SpectrogramDelta(reset: info[0] != 0, columns: Int(info[1]), rows: rows,
                first: Int(info[3]), count: count, shown: Int(info[5]),
                values: Array(spectrogramValues.prefix(count * rows))),
            timing: timing
        )
    }
}
