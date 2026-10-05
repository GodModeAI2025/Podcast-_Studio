import Foundation

/// ITU-R BS.1770-4 / EBU R128 loudness measurement.
///
/// Mono content is measured as a single channel with weight 1.0 (as ffmpeg `ebur128`
/// and most podcast tooling do).
public enum Loudness {
    public static let absoluteGate = -70.0
    public static let relativeGateOffset = -10.0

    /// K-weighting pre-filter (stage 1, high shelf) + RLB high-pass (stage 2) for any sample
    /// rate, using the analog-prototype parameters from libebur128. At 48 kHz this
    /// reproduces the coefficients tabulated in BS.1770-4 to 1e-8.
    public static func kWeighting(sampleRate: Double) -> [Biquad] {
        var f0 = 1681.974450955533
        let g = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, g / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0,
                           b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0,
                           a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        let hp = Biquad(b0: 1, b1: -2, b2: 1,
                        a1: 2 * (k * k - 1) / a0,
                        a2: (1 - k / q + k * k) / a0)
        return [shelf, hp]
    }

    /// Integrated loudness in LUFS of de-interleaved channels. Returns `-inf` for silence
    /// or content shorter than one 400 ms block.
    public static func integrated(_ channels: [[Float]], sampleRate: Double) -> Double {
        let blocks = blockPowers(channels, sampleRate: sampleRate)
        return gatedLoudness(blocks)
    }

    /// Mean-square power (sum over channels, K-weighted) of 400 ms blocks with 75 % overlap.
    public static func blockPowers(_ channels: [[Float]], sampleRate: Double) -> [Double] {
        guard let frames = channels.first?.count, frames > 0 else { return [] }
        let blockLen = Int((0.4 * sampleRate).rounded())
        let hop = Int((0.1 * sampleRate).rounded())
        guard frames >= blockLen else { return [] }

        // Squared K-weighted samples, summed over channels, as prefix sums per hop.
        let hopCount = frames / hop
        var hopEnergy = [Double](repeating: 0, count: hopCount)
        for channel in channels {
            var filters = kWeighting(sampleRate: sampleRate)
            for i in 0..<(hopCount * hop) {
                var y = Double(channel[i])
                for f in filters.indices { y = filters[f].process(y) }
                hopEnergy[i / hop] += y * y
            }
        }
        let hopsPerBlock = blockLen / hop  // 4
        guard hopCount >= hopsPerBlock else { return [] }
        var powers: [Double] = []
        powers.reserveCapacity(hopCount - hopsPerBlock + 1)
        var window = hopEnergy[0..<hopsPerBlock].reduce(0, +)
        powers.append(window / Double(blockLen))
        for j in hopsPerBlock..<hopCount {
            window += hopEnergy[j] - hopEnergy[j - hopsPerBlock]
            powers.append(max(window, 0) / Double(blockLen))
        }
        return powers
    }

    public static func gatedLoudness(_ blockPowers: [Double]) -> Double {
        func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(p) }
        let absGated = blockPowers.filter { $0 > 0 && lufs($0) > absoluteGate }
        guard !absGated.isEmpty else { return -.infinity }
        let relThreshold = lufs(absGated.reduce(0, +) / Double(absGated.count)) + relativeGateOffset
        let relGated = absGated.filter { lufs($0) > relThreshold }
        guard !relGated.isEmpty else { return -.infinity }
        return lufs(relGated.reduce(0, +) / Double(relGated.count))
    }

    /// Highest absolute sample value in dBFS.
    public static func samplePeakDB(_ channels: [[Float]]) -> Double {
        var peak: Float = 0
        for c in channels { for s in c { peak = max(peak, abs(s)) } }
        return Decibel.fromLinear(Double(peak))
    }

    /// Approximate true peak (4× oversampling by windowed-sinc interpolation), dBTP.
    public static func truePeakDB(_ channels: [[Float]]) -> Double {
        let taps = 8
        var peak = 0.0
        for c in channels where !c.isEmpty {
            for i in c.indices {
                peak = max(peak, Double(abs(c[i])))
                for phase in 1..<4 {
                    let frac = Double(phase) / 4
                    var acc = 0.0
                    for k in (-taps + 1)...taps {
                        let idx = i + k
                        guard idx >= 0, idx < c.count else { continue }
                        let x = Double(k) - frac
                        let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                        let window = 0.5 * (1 + cos(Double.pi * x / Double(taps)))
                        acc += Double(c[idx]) * sinc * window
                    }
                    peak = max(peak, abs(acc))
                }
            }
        }
        return Decibel.fromLinear(peak)
    }
}

/// Real-time level meter for the UI (RMS + peak with hold/decay), dBFS.
public struct LevelMeter: Sendable, Equatable {
    public private(set) var rmsDB: Double = -160
    public private(set) var peakDB: Double = -160
    public private(set) var peakHoldDB: Double = -160
    public private(set) var clipped = false
    private var holdRemaining: TimeInterval = 0

    public var holdTime: TimeInterval = 1.5
    public var decayDBPerSecond: Double = 20
    /// Samples at or above this level count as clipping.
    public var clipThresholdDB: Double = -0.1

    public init() {}

    public mutating func process(_ samples: UnsafeBufferPointer<Float>, duration: TimeInterval) {
        var sum: Float = 0
        var peak: Float = 0
        for s in samples {
            sum += s * s
            peak = max(peak, abs(s))
        }
        let rms = samples.isEmpty ? 0 : sqrt(sum / Float(samples.count))
        rmsDB = max(-160, Decibel.fromLinear(Double(rms)))
        let p = max(-160, Decibel.fromLinear(Double(peak)))
        peakDB = max(p, peakDB - decayDBPerSecond * duration)
        if p >= peakHoldDB {
            peakHoldDB = p
            holdRemaining = holdTime
        } else {
            holdRemaining -= duration
            if holdRemaining <= 0 { peakHoldDB = max(p, peakHoldDB - decayDBPerSecond * duration) }
        }
        if p >= clipThresholdDB { clipped = true }
    }

    public mutating func process(_ samples: [Float], duration: TimeInterval) {
        samples.withUnsafeBufferPointer { process($0, duration: duration) }
    }

    public mutating func resetClip() { clipped = false }

    /// 0…1 for meter bars, mapping -60…0 dBFS.
    public static func normalized(_ db: Double, floor: Double = -60) -> Double {
        min(1, max(0, (db - floor) / -floor))
    }
}
