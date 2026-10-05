import Foundation

// MARK: - Timeline / alignment

/// A recording window on the shared clock, defined by the owner's transport commands
/// (start/resume … pause/stop). Every device records exactly one segment per window.
public struct RecordingWindow: Codable, Sendable, Equatable {
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval?

    public init(index: Int, start: TimeInterval, end: TimeInterval? = nil) {
        self.index = index
        self.start = start
        self.end = end
    }
}

/// A contiguous run of frames in a local track file.
public struct RecordingSegment: Codable, Sendable, Equatable {
    /// Window this segment belongs to.
    public var window: Int
    /// Shared-clock time of the segment's first frame.
    public var sharedStart: TimeInterval
    /// First frame of the segment inside the track file.
    public var fileFrameOffset: Int64
    public var frameCount: Int64

    public init(window: Int, sharedStart: TimeInterval, fileFrameOffset: Int64, frameCount: Int64) {
        self.window = window
        self.sharedStart = sharedStart
        self.fileFrameOffset = fileFrameOffset
        self.frameCount = frameCount
    }
}

public struct SegmentPlacement: Sendable, Equatable {
    public var segment: RecordingSegment
    /// Frames to skip at the beginning of the segment (recorded before the window opened).
    public var skipFrames: Int64
    /// Destination frame on the output timeline.
    public var timelineFrame: Int64
}

/// Maps device-local segments onto one common output timeline. Pauses are removed:
/// window k starts on the timeline where window k-1 ended.
public struct TimelineAligner: Sendable {
    public var windows: [RecordingWindow]
    public var sampleRate: Double

    public init(windows: [RecordingWindow], sampleRate: Double) {
        self.windows = windows.sorted { $0.index < $1.index }
        self.sampleRate = sampleRate
    }

    /// Duration of each window in frames. Open windows use the longest segment seen.
    public func windowLengths(allSegments: [RecordingSegment]) -> [Int: Int64] {
        var lengths: [Int: Int64] = [:]
        for w in windows {
            if let end = w.end {
                lengths[w.index] = Int64(((end - w.start) * sampleRate).rounded())
            } else {
                let longest = allSegments.filter { $0.window == w.index }.map { seg -> Int64 in
                    let lead = Int64(((seg.sharedStart - w.start) * sampleRate).rounded())
                    return lead + seg.frameCount
                }.max() ?? 0
                lengths[w.index] = longest
            }
        }
        return lengths
    }

    public func placements(for segments: [RecordingSegment], allSegments: [RecordingSegment]) -> [SegmentPlacement] {
        let lengths = windowLengths(allSegments: allSegments)
        var windowStartFrame: [Int: Int64] = [:]
        var cursor: Int64 = 0
        for w in windows {
            windowStartFrame[w.index] = cursor
            cursor += lengths[w.index] ?? 0
        }
        return segments.compactMap { seg in
            guard let window = windows.first(where: { $0.index == seg.window }),
                  let base = windowStartFrame[seg.window] else { return nil }
            let lead = Int64(((seg.sharedStart - window.start) * sampleRate).rounded())
            let skip = max(0, -lead)
            return SegmentPlacement(segment: seg, skipFrames: skip, timelineFrame: base + max(0, lead))
        }
    }

    public func totalFrames(allSegments: [RecordingSegment]) -> Int64 {
        windowLengths(allSegments: allSegments).values.reduce(0, +)
    }

    /// Renders a mono track onto the timeline. `fileSamples` is the complete local file.
    public func render(fileSamples: [Float], segments: [RecordingSegment], allSegments: [RecordingSegment]) -> [Float] {
        let total = Int(totalFrames(allSegments: allSegments))
        var out = [Float](repeating: 0, count: total)
        let windowEnd = windowEndFrames(allSegments: allSegments)
        for p in placements(for: segments, allSegments: allSegments) {
            var src = Int(p.segment.fileFrameOffset + p.skipFrames)
            let srcEnd = min(fileSamples.count, Int(p.segment.fileFrameOffset + p.segment.frameCount))
            var dst = Int(p.timelineFrame)
            // Never spill into the next window (device stopped late).
            let dstEnd = min(total, Int(windowEnd[p.segment.window] ?? Int64(total)))
            while src < srcEnd && dst < dstEnd {
                out[dst] = fileSamples[src]
                src += 1
                dst += 1
            }
        }
        return out
    }

    private func windowEndFrames(allSegments: [RecordingSegment]) -> [Int: Int64] {
        let lengths = windowLengths(allSegments: allSegments)
        var ends: [Int: Int64] = [:]
        var cursor: Int64 = 0
        for w in windows {
            cursor += lengths[w.index] ?? 0
            ends[w.index] = cursor
        }
        return ends
    }
}

// MARK: - Loudness normalisation

public struct LoudnessTarget: Sendable, Equatable, Codable {
    public var integratedLUFS: Double
    public var ceilingDB: Double

    public init(integratedLUFS: Double = -16, ceilingDB: Double = -1.5) {
        self.integratedLUFS = integratedLUFS
        self.ceilingDB = ceilingDB
    }

    public static let podcast = LoudnessTarget()
}

public struct NormalizationReport: Sendable, Equatable, Codable {
    public var inputLUFS: Double
    public var outputLUFS: Double
    public var appliedGainDB: Double
    public var outputPeakDB: Double
}

public enum LoudnessNormalizer {
    /// Gain + peak limiting, iterated because limiting slightly lowers the loudness.
    @discardableResult
    public static func normalize(_ channels: inout [[Float]], sampleRate: Double,
                                 target: LoudnessTarget = .podcast, maxPasses: Int = 8) -> NormalizationReport {
        let input = Loudness.integrated(channels, sampleRate: sampleRate)
        guard input.isFinite else {
            return NormalizationReport(inputLUFS: input, outputLUFS: input, appliedGainDB: 0,
                                       outputPeakDB: Loudness.samplePeakDB(channels))
        }
        let original = channels
        var totalGain = target.integratedLUFS - input
        var measured = input
        let limiter = PeakLimiter(ceilingDB: target.ceilingDB)
        for _ in 0..<maxPasses {
            channels = original
            let g = Float(Decibel.toLinear(totalGain))
            for c in channels.indices {
                for i in channels[c].indices { channels[c][i] *= g }
            }
            limiter.process(&channels, sampleRate: sampleRate)
            measured = Loudness.integrated(channels, sampleRate: sampleRate)
            let error = target.integratedLUFS - measured
            if abs(error) < 0.1 { break }
            totalGain += error
            totalGain = min(totalGain, 40)  // never boost noise beyond reason
        }
        return NormalizationReport(inputLUFS: input, outputLUFS: measured, appliedGainDB: totalGain,
                                   outputPeakDB: Loudness.samplePeakDB(channels))
    }
}

// MARK: - Mixdown

public enum Mixdown {
    /// Sums equally long mono tracks. Each input should already be loudness-normalised,
    /// so all speakers sit at the same level.
    public static func sum(_ tracks: [[Float]]) -> [Float] {
        let n = tracks.map(\.count).max() ?? 0
        var out = [Float](repeating: 0, count: n)
        for t in tracks {
            for i in t.indices { out[i] += t[i] }
        }
        return out
    }
}

// MARK: - Pipeline

public struct SpeakerInput: Sendable {
    public var name: String
    /// Mono samples already placed on the shared timeline (see `TimelineAligner.render`).
    public var samples: [Float]

    public init(name: String, samples: [Float]) {
        self.name = name
        self.samples = samples
    }
}

public struct SpeakerOutput: Sendable {
    public var name: String
    public var samples: [Float]
    public var report: NormalizationReport
}

public struct PostProductionResult: Sendable {
    public var speakers: [SpeakerOutput]
    public var mix: [Float]
    public var mixReport: NormalizationReport
}

/// Per-speaker optimisation + sum (M6). The voice processing step is injected so that
/// devices can use the AVAudioEngine chain while `pstool`/tests use `VoiceChain`.
public enum PostProductionPipeline {
    public static func run(
        speakers: [SpeakerInput],
        sampleRate: Double,
        target: LoudnessTarget = .podcast,
        voiceProcessing: (inout [Float]) -> Void
    ) -> PostProductionResult {
        var outputs: [SpeakerOutput] = []
        for speaker in speakers {
            var s = speaker.samples
            voiceProcessing(&s)
            var ch = [s]
            let report = LoudnessNormalizer.normalize(&ch, sampleRate: sampleRate, target: target)
            outputs.append(SpeakerOutput(name: speaker.name, samples: ch[0], report: report))
        }
        // Sum the processed, unlimited-level-matched voices, then normalise the sum.
        var mix = [Mixdown.sum(outputs.map(\.samples))]
        let mixReport = LoudnessNormalizer.normalize(&mix, sampleRate: sampleRate, target: target)
        return PostProductionResult(speakers: outputs, mix: mix[0], mixReport: mixReport)
    }
}
