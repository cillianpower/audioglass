import Foundation

// Display gain only: snapshots, measured levels and stereo correlation stay raw.
struct DisplayNormalization {
    private(set) var gain: CGFloat = 1
    private var hasSignal = false

    mutating func update(peak: Float, elapsed: TimeInterval) {
        guard peak.isFinite, peak > 0.00001 else {
            gain = 1
            hasSignal = false
            return
        }
        // Fit to 95% of the graph; limit amplification below -80 dBFS.
        let target = CGFloat(0.95 / max(0.0001, peak))
        if !hasSignal || target < gain {
            gain = target
        } else {
            // Relax over 250 ms to avoid pumping as quiet peaks fluctuate.
            gain += (target - gain) * CGFloat(1 - exp(-elapsed / 0.25))
        }
        hasSignal = true
    }
}
