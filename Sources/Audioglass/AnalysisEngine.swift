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
    }
}

import DSPBridge

struct AnalysisFrame: Sendable {
    let frequencies: [Float]
    let levels: [Float]
    let waveform: [Float]
    var history: [Float] = []
    var stereo: [Float] = []
    var metrics: [Float] = []
    var spectrogram: SpectrogramDelta?
    var timing: [Float] = [48000, 0, 0, 256.0 / 48000, 0]
}

// The delegate's serial analysis queue owns all access to this handle.
final class AnalysisEngine: @unchecked Sendable {
    private var handle = ag_create()!
    private var pcm = [Float](repeating: 0, count: 8192)
    private var dropped: UInt64 = 0
    private var history = [Float](repeating: 0, count: 4096)
    private var stereo = [Float](repeating: 0, count: 4000)
    private var metrics = [Float](repeating: 0, count: 7)
    private var spectrogramValues: [Float] = []
    private var frequencies = [Float](repeating: 0, count: 16385)
    private var levels = [Float](repeating: 0, count: 16385)
    private var waveform = [Float](repeating: 0, count: 48000)

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

        let counts = ag_process(handle, smoothing, &frequencies, &levels, 16385, &waveform, 48000)
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
            history: Array(history.prefix(Int(meterCounts[0]) * 4)),
            stereo: Array(stereo.prefix(Int(meterCounts[1]) * 2)),
            metrics: metrics,
            spectrogram: SpectrogramDelta(reset: info[0] != 0, columns: Int(info[1]), rows: rows,
                first: Int(info[3]), count: count, shown: Int(info[5]),
                values: Array(spectrogramValues.prefix(count * rows))),
            timing: timing
        )
    }
}
