import Foundation
import XCTest
@testable import StudioCore

func sine(frequency: Double, amplitude: Double, seconds: Double, sampleRate: Double = 48_000) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

final class LoudnessTests: XCTestCase {
    /// EBU Tech 3341 / BS.1770: a 997 Hz sine at 0 dBFS peak in one channel reads -3.01 LUFS.
    func testFullScaleSineReference() {
        let s = sine(frequency: 997, amplitude: 1, seconds: 5)
        XCTAssertEqual(Loudness.integrated([s], sampleRate: 48_000), -3.01, accuracy: 0.05)
    }

    func testStereoSineAt23() {
        // EBU 3341 test 1: stereo 1 kHz at -23 dBFS each channel → -23 LUFS ±0.1
        let a = sine(frequency: 1000, amplitude: Decibel.toLinear(-23), seconds: 20)
        XCTAssertEqual(Loudness.integrated([a, a], sampleRate: 48_000), -23, accuracy: 0.1)
    }

    func testOtherSampleRate() {
        let s = sine(frequency: 997, amplitude: 1, seconds: 5, sampleRate: 44_100)
        XCTAssertEqual(Loudness.integrated([s], sampleRate: 44_100), -3.01, accuracy: 0.05)
    }

    func testKWeighting48kMatchesStandardCoefficients() {
        let f = Loudness.kWeighting(sampleRate: 48_000)
        XCTAssertEqual(f[0].b0, 1.53512485958697, accuracy: 1e-6)
        XCTAssertEqual(f[0].b1, -2.69169618940638, accuracy: 1e-6)
        XCTAssertEqual(f[0].b2, 1.19839281085285, accuracy: 1e-6)
        XCTAssertEqual(f[0].a1, -1.69065929318241, accuracy: 1e-6)
        XCTAssertEqual(f[0].a2, 0.73248077421585, accuracy: 1e-6)
        XCTAssertEqual(f[1].a1, -1.99004745483398, accuracy: 1e-6)
        XCTAssertEqual(f[1].a2, 0.99007225036621, accuracy: 1e-6)
    }

    func testGatingIgnoresSilence() {
        let tone = sine(frequency: 1000, amplitude: Decibel.toLinear(-20), seconds: 10)
        let withSilence = tone + [Float](repeating: 0, count: 48_000 * 30)
        let l1 = Loudness.integrated([tone], sampleRate: 48_000)
        let l2 = Loudness.integrated([withSilence], sampleRate: 48_000)
        // Blocks straddling the tone/silence edge legitimately pass the relative gate.
        XCTAssertEqual(l1, l2, accuracy: 0.1)
        XCTAssertEqual(l1, -23.01, accuracy: 0.05)
    }

    func testSilenceAndTooShort() {
        XCTAssertEqual(Loudness.integrated([[Float](repeating: 0, count: 48_000)], sampleRate: 48_000), -.infinity)
        XCTAssertEqual(Loudness.integrated([[0.5, -0.5]], sampleRate: 48_000), -.infinity)
    }

    func testTruePeakAboveSamplePeak() {
        // fs/4 sine with 45° phase: samples at ±0.707, true peak 1.0
        let s: [Float] = (0..<400).map { Float(sin(Double.pi / 2 * Double($0) + .pi / 4)) }
        XCTAssertEqual(Loudness.samplePeakDB([s]), -3.01, accuracy: 0.05)
        XCTAssertGreaterThan(Loudness.truePeakDB([s]), -0.5)
    }
}

final class DynamicsTests: XCTestCase {
    func testBiquadResponses() {
        let hp = Biquad.highPass(frequency: 80, sampleRate: 48_000)
        XCTAssertEqual(hp.magnitudeDB(at: 80, sampleRate: 48_000), -3.01, accuracy: 0.1)
        XCTAssertLessThan(hp.magnitudeDB(at: 20, sampleRate: 48_000), -20)
        XCTAssertEqual(hp.magnitudeDB(at: 1000, sampleRate: 48_000), 0, accuracy: 0.1)
        let peak = Biquad.peaking(frequency: 4000, gainDB: 3, q: 1, sampleRate: 48_000)
        XCTAssertEqual(peak.magnitudeDB(at: 4000, sampleRate: 48_000), 3, accuracy: 0.01)
    }

    func testCompressorStaticCurve() {
        let c = Compressor(thresholdDB: -20, ratio: 4, kneeDB: 0)
        XCTAssertEqual(c.gainReductionDB(forLevel: -30), 0)
        XCTAssertEqual(c.gainReductionDB(forLevel: -10), -7.5, accuracy: 1e-9)
        let soft = Compressor(thresholdDB: -20, ratio: 4, kneeDB: 6)
        XCTAssertLessThan(soft.gainReductionDB(forLevel: -20), 0)
        XCTAssertEqual(soft.gainReductionDB(forLevel: -10), -7.5, accuracy: 1e-9)
    }

    func testCompressorReducesLoudPart() {
        var s = sine(frequency: 500, amplitude: 0.9, seconds: 1)
        Compressor(thresholdDB: -20, ratio: 4).process(&s, sampleRate: 48_000)
        let tail = Array(s[24_000...])
        let peak = tail.map { abs($0) }.max()!
        // 0.9 ≈ -0.9 dBFS; above -20 by 19 dB → reduced by ~14 dB
        XCTAssertEqual(Decibel.fromLinear(Double(peak)), -0.9 - 14.3, accuracy: 1.5)
    }

    func testLimiterCeiling() {
        var ch = [sine(frequency: 200, amplitude: 1.5, seconds: 0.5), sine(frequency: 300, amplitude: 0.5, seconds: 0.5)]
        PeakLimiter(ceilingDB: -1).process(&ch, sampleRate: 48_000)
        XCTAssertLessThanOrEqual(Loudness.samplePeakDB(ch), -1 + 1e-4)
    }

    func testNormalizerHitsTarget() {
        for level in [-40.0, -25, -6] {
            var ch = [sine(frequency: 440, amplitude: Decibel.toLinear(level), seconds: 5)]
            let report = LoudnessNormalizer.normalize(&ch, sampleRate: 48_000)
            XCTAssertEqual(report.outputLUFS, -16, accuracy: 0.15, "level \(level)")
            XCTAssertLessThanOrEqual(report.outputPeakDB, -1.5 + 1e-4)
        }
    }

    func testPipelineSpeakerLevelsWithin2dB() {
        // Speakers recorded 30 dB apart, taking turns.
        let sr = 48_000.0
        let n = Int(sr * 12)
        func speaker(_ k: Int, level: Double, pitch: Double) -> [Float] {
            (0..<n).map { i in
                let t = Double(i) / sr
                guard Int(t / 2) % 3 == k else { return 0 }
                var v = 0.0
                for h in 1...6 { v += sin(2 * .pi * pitch * Double(h) * t) / Double(h) }
                return Float(v * 0.3 * Decibel.toLinear(level) * max(0, sin(2 * .pi * 3 * t)))
            }
        }
        let inputs = [
            SpeakerInput(name: "a", samples: speaker(0, level: -3, pitch: 120)),
            SpeakerInput(name: "b", samples: speaker(1, level: -18, pitch: 190)),
            SpeakerInput(name: "c", samples: speaker(2, level: -33, pitch: 150)),
        ]
        let result = PostProductionPipeline.run(speakers: inputs, sampleRate: sr) { VoiceChain.process(&$0, sampleRate: sr) }
        let levels = result.speakers.map { Loudness.integrated([$0.samples], sampleRate: sr) }
        XCTAssertLessThan(levels.max()! - levels.min()!, 2, "\(levels)")
        XCTAssertEqual(result.mixReport.outputLUFS, -16, accuracy: 0.5)
        XCTAssertEqual(result.mix.count, n)
    }
}

final class TimelineTests: XCTestCase {
    let sr = 48_000.0

    func testAlignmentRemovesPausesAndCompensatesStartSkew() {
        // Window 0: 100.0 … 101.0, pause, window 1: 200.0 … 200.5 (shared clock)
        let windows = [RecordingWindow(index: 0, start: 100, end: 101), RecordingWindow(index: 1, start: 200, end: 200.5)]
        let aligner = TimelineAligner(windows: windows, sampleRate: sr)
        // Device A starts 10 ms late, device B 5 ms early.
        let a = [
            RecordingSegment(window: 0, sharedStart: 100.010, fileFrameOffset: 0, frameCount: 48_000),
            RecordingSegment(window: 1, sharedStart: 200.0, fileFrameOffset: 48_000, frameCount: 24_000),
        ]
        let b = [
            RecordingSegment(window: 0, sharedStart: 99.995, fileFrameOffset: 0, frameCount: 48_240),
            RecordingSegment(window: 1, sharedStart: 200.0, fileFrameOffset: 48_240, frameCount: 24_000),
        ]
        let all = a + b
        XCTAssertEqual(aligner.totalFrames(allSegments: all), 72_000)
        let pa = aligner.placements(for: a, allSegments: all)
        XCTAssertEqual(pa[0].timelineFrame, 480)
        XCTAssertEqual(pa[0].skipFrames, 0)
        XCTAssertEqual(pa[1].timelineFrame, 48_000)
        let pb = aligner.placements(for: b, allSegments: all)
        XCTAssertEqual(pb[0].timelineFrame, 0)
        XCTAssertEqual(pb[0].skipFrames, 240)

        // A click at shared time 100.5 must land on the same timeline frame for both devices.
        var fileA = [Float](repeating: 0, count: 72_000)
        var fileB = [Float](repeating: 0, count: 72_240)
        fileA[Int(((100.5 - 100.010) * sr).rounded())] = 1
        fileB[Int(((100.5 - 99.995) * sr).rounded())] = 1
        let ra = aligner.render(fileSamples: fileA, segments: a, allSegments: all)
        let rb = aligner.render(fileSamples: fileB, segments: b, allSegments: all)
        XCTAssertEqual(ra.firstIndex(of: 1), 24_000)
        XCTAssertEqual(rb.firstIndex(of: 1), 24_000)
    }

    func testOpenWindowUsesLongestSegment() {
        let aligner = TimelineAligner(windows: [RecordingWindow(index: 0, start: 10)], sampleRate: sr)
        let segs = [
            RecordingSegment(window: 0, sharedStart: 10, fileFrameOffset: 0, frameCount: 1000),
            RecordingSegment(window: 0, sharedStart: 10.001, fileFrameOffset: 0, frameCount: 1000),
        ]
        XCTAssertEqual(aligner.totalFrames(allSegments: segs), 1048)
    }
}
