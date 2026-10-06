import Foundation

struct MeterSettings: Sendable {
    var channel = UserDefaults.standard.integer(forKey: "AnalysisChannel")
    var fftSize = UserDefaults.standard.object(forKey: "FFTSize") as? Int ?? 16384
    var weighted = UserDefaults.standard.bool(forKey: "AWeighting")
    var floor = UserDefaults.standard.object(forKey: "SpectrumFloor") as? Int ?? -120
    var cycles = UserDefaults.standard.object(forKey: "ScopeCycles") as? Int ?? 2
    var waveSpeed = UserDefaults.standard.object(forKey: "WaveSpeed") as? Int ?? 200
    init() {
        if !(0...3).contains(channel) { channel = 0 }
        if ![4096, 8192, 16384, 32768].contains(fftSize) { fftSize = 16384 }
        if ![-60, -90, -120].contains(floor) { floor = -120 }
        if ![0, 1, 2, 4].contains(cycles) { cycles = 2 }
        if ![100, 200, 400].contains(waveSpeed) { waveSpeed = 200 }
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
    var spectrogram: [UInt8] = []
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
    private var image = [UInt8](repeating: 0, count: 512 * 192)
    private var frequencies = [Float](repeating: 0, count: 16385)
    private var levels = [Float](repeating: 0, count: 16385)
    private var waveform = [Float](repeating: 0, count: 48000)

    deinit { ag_destroy(handle) }

    func reset() {
        ag_destroy(handle)
        handle = ag_create()!
        dropped = 0
    }

    func process(input: CaptureInput?, settings: MeterSettings, smoothing: Float) -> AnalysisFrame {
        ag_configure(handle, Int32(settings.channel), Int32(settings.fftSize), settings.weighted ? 1 : 0,
            Float(settings.floor), Int32(settings.cycles), Float(settings.waveSpeed), smoothing)
        if let input {
            let losses = ag_transport_dropped(input.transport)
            if losses != dropped {
                reset()
                dropped = losses
                ag_configure(handle, Int32(settings.channel), Int32(settings.fftSize), settings.weighted ? 1 : 0,
                    Float(settings.floor), Int32(settings.cycles), Float(settings.waveSpeed), smoothing)
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
        ag_read_meters(handle, &history, &stereo, &metrics, &image, &meterCounts)
        var timing = [Float](repeating: 0, count: 5)
        ag_read_timing(handle, &timing)
        return AnalysisFrame(
            frequencies: Array(frequencies.prefix(Int(counts.spectrum_count))),
            levels: Array(levels.prefix(Int(counts.spectrum_count))),
            waveform: Array(waveform.prefix(Int(counts.scope_count))),
            history: Array(history.prefix(Int(meterCounts[0]) * 4)),
            stereo: Array(stereo.prefix(Int(meterCounts[1]) * 2)),
            metrics: metrics, spectrogram: image, timing: timing
        )
    }
}
