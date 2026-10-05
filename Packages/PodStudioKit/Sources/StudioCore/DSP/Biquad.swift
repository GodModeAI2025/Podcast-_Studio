import Foundation

/// Second-order IIR filter (transposed direct form II), double precision state.
public struct Biquad: Sendable, Equatable {
    public var b0: Double, b1: Double, b2: Double
    public var a1: Double, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    /// Coefficients normalised so that a0 == 1.
    public init(b0: Double, b1: Double, b2: Double, a0: Double = 1, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func process(_ samples: inout [Float]) {
        for i in samples.indices {
            samples[i] = Float(process(Double(samples[i])))
        }
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    // MARK: RBJ Audio-EQ-Cookbook designs

    public static func highPass(frequency: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2,
                      a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        return Biquad(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a,
                      a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
    }

    public static func highShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let sa = 2 * sqrt(a) * alpha
        return Biquad(b0: a * ((a + 1) + (a - 1) * c + sa),
                      b1: -2 * a * ((a - 1) + (a + 1) * c),
                      b2: a * ((a + 1) + (a - 1) * c - sa),
                      a0: (a + 1) - (a - 1) * c + sa,
                      a1: 2 * ((a - 1) - (a + 1) * c),
                      a2: (a + 1) - (a - 1) * c - sa)
    }

    /// Magnitude response in dB at `frequency` (used by tests).
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func cplx(_ c0: Double, _ c1: Double, _ c2: Double) -> (Double, Double) {
            (c0 + c1 * cos(-w) + c2 * cos(-2 * w), c1 * sin(-w) + c2 * sin(-2 * w))
        }
        let n = cplx(b0, b1, b2)
        let d = cplx(1, a1, a2)
        let mag = sqrt(n.0 * n.0 + n.1 * n.1) / sqrt(d.0 * d.0 + d.1 * d.1)
        return 20 * log10(mag)
    }
}

public enum Decibel {
    public static func toLinear(_ db: Double) -> Double { pow(10, db / 20) }
    public static func fromLinear(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -.infinity }
}
