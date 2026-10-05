import Foundation

/// Feed-forward compressor with soft knee, operating on dB levels.
public struct Compressor: Sendable, Equatable {
    public var thresholdDB: Double
    public var ratio: Double
    public var kneeDB: Double
    public var attack: TimeInterval
    public var release: TimeInterval

    public init(thresholdDB: Double = -20, ratio: Double = 3, kneeDB: Double = 6,
                attack: TimeInterval = 0.010, release: TimeInterval = 0.150) {
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.kneeDB = kneeDB
        self.attack = attack
        self.release = release
    }

    /// Static gain reduction (≤ 0 dB) for an input level.
    public func gainReductionDB(forLevel x: Double) -> Double {
        let over = x - thresholdDB
        if kneeDB > 0, abs(over) <= kneeDB / 2 {
            let k = over + kneeDB / 2
            return (1 / ratio - 1) * k * k / (2 * kneeDB)
        }
        return over > 0 ? (1 / ratio - 1) * over : 0
    }

    public func process(_ samples: inout [Float], sampleRate: Double) {
        let aCoef = exp(-1 / (attack * sampleRate))
        let rCoef = exp(-1 / (release * sampleRate))
        var env = 0.0  // peak envelope of |x|, linear
        for i in samples.indices {
            let x = Double(abs(samples[i]))
            let coef = x > env ? aCoef : rCoef
            env = coef * env + (1 - coef) * x
            guard env > 1e-9 else { continue }
            let reduction = gainReductionDB(forLevel: Decibel.fromLinear(env))
            if reduction < 0 { samples[i] *= Float(Decibel.toLinear(reduction)) }
        }
    }
}

/// Offline look-ahead brick-wall peak limiter. Guarantees |y| ≤ ceiling.
public struct PeakLimiter: Sendable, Equatable {
    public var ceilingDB: Double
    public var lookahead: TimeInterval
    public var release: TimeInterval

    public init(ceilingDB: Double = -1.5, lookahead: TimeInterval = 0.005, release: TimeInterval = 0.080) {
        self.ceilingDB = ceilingDB
        self.lookahead = lookahead
        self.release = release
    }

    /// Limits all channels with a linked gain curve.
    public func process(_ channels: inout [[Float]], sampleRate: Double) {
        guard let n = channels.first?.count, n > 0 else { return }
        let ceiling = Decibel.toLinear(ceilingDB)
        var gain = [Double](repeating: 1, count: n)
        for i in 0..<n {
            var peak: Float = 0
            for c in channels.indices { peak = max(peak, abs(channels[c][i])) }
            if Double(peak) > ceiling { gain[i] = ceiling / Double(peak) }
        }
        // Backward pass: linear ramp down over the look-ahead window before each peak.
        let la = max(1, Int(lookahead * sampleRate))
        let step = 1.0 / Double(la)
        if n > 1 {
            for i in stride(from: n - 2, through: 0, by: -1) {
                gain[i] = min(gain[i], gain[i + 1] + step)
            }
        }
        // Forward pass: exponential release.
        let rCoef = exp(-1 / (release * sampleRate))
        for i in 1..<n {
            let released = 1 - (1 - gain[i - 1]) * rCoef
            gain[i] = min(gain[i], released)
        }
        for c in channels.indices {
            for i in 0..<n {
                channels[c][i] = Float(Double(channels[c][i]) * gain[i])
            }
        }
        // Guard against float rounding exactly at the ceiling.
        let hard = Float(ceiling)
        for c in channels.indices {
            for i in 0..<n where abs(channels[c][i]) > hard {
                channels[c][i] = channels[c][i] > 0 ? hard : -hard
            }
        }
    }
}

/// Pure-Swift voice chain (HPF → presence → compressor). Mirrors the AVAudioEngine chain
/// used on device (`PostProductionEngine`) and is used by `pstool` and as a fallback.
public struct VoiceChainSettings: Sendable, Equatable, Codable {
    public var highPassHz: Double = 80
    public var presenceHz: Double = 4_000
    public var presenceGainDB: Double = 2.5
    public var presenceQ: Double = 0.9
    public var mudHz: Double = 300
    public var mudGainDB: Double = -1.5
    public var compressorThresholdDB: Double = -24
    public var compressorRatio: Double = 3
    public var compressorAttack: TimeInterval = 0.010
    public var compressorRelease: TimeInterval = 0.150

    public init() {}

    public static let podcast = VoiceChainSettings()
}

public enum VoiceChain {
    public static func process(_ samples: inout [Float], sampleRate: Double, settings: VoiceChainSettings = .podcast) {
        var filters = [
            Biquad.highPass(frequency: settings.highPassHz, q: 0.7071, sampleRate: sampleRate),
            Biquad.peaking(frequency: settings.mudHz, gainDB: settings.mudGainDB, q: 1.0, sampleRate: sampleRate),
            Biquad.peaking(frequency: settings.presenceHz, gainDB: settings.presenceGainDB, q: settings.presenceQ, sampleRate: sampleRate),
        ]
        for f in filters.indices { filters[f].process(&samples) }
        let comp = Compressor(thresholdDB: settings.compressorThresholdDB, ratio: settings.compressorRatio,
                              attack: settings.compressorAttack, release: settings.compressorRelease)
        comp.process(&samples, sampleRate: sampleRate)
    }
}
