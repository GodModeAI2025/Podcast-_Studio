import Foundation

/// Sample-accurate execution of transport commands inside the audio input stream.
///
/// Commands arrive over the network ahead of time (the issuer schedules them ~0.75 s in
/// the future on the shared clock). For every captured buffer the scheduler decides which
/// frame ranges go into the track file and where segments begin and end, so that a
/// command takes effect on exactly the frame whose host time matches the command time on
/// every device — independent of buffer size and network latency.
public struct CaptureScheduler: Sendable {
    public struct Command: Sendable, Equatable {
        public var action: RecordAction
        /// Local host time (already converted from the shared clock).
        public var at: TimeInterval
        public var window: Int

        public init(action: RecordAction, at: TimeInterval, window: Int) {
            self.action = action
            self.at = at
            self.window = window
        }
    }

    public enum Event: Sendable, Equatable {
        case segmentStarted(RecordingSegment)
        /// The segment of `window` ended after `frameCount` frames.
        case segmentEnded(window: Int, frameCount: Int64)
        case stopped
    }

    public struct Output: Sendable, Equatable {
        /// Frame ranges of the current buffer to append to the file, in order.
        public var writes: [Range<Int>] = []
        public var events: [Event] = []
    }

    public private(set) var isWriting = false
    public private(set) var framesWritten: Int64 = 0
    public private(set) var currentSegment: RecordingSegment?
    public private(set) var pending: [Command] = []
    /// shared − local (from `ClockSynchronizer.offset`), used to stamp segments.
    public var clockOffset: TimeInterval

    public init(clockOffset: TimeInterval = 0, framesWritten: Int64 = 0) {
        self.clockOffset = clockOffset
        self.framesWritten = framesWritten
    }

    public mutating func schedule(_ command: Command) {
        pending.append(command)
        pending.sort { $0.at < $1.at }
    }

    /// Processes one input buffer whose first frame was captured at local host time
    /// `bufferStart`.
    public mutating func process(bufferStart: TimeInterval, frameCount: Int, sampleRate: Double) -> Output {
        var out = Output()
        let bufferEnd = bufferStart + Double(frameCount) / sampleRate
        var cursor = 0

        while let next = pending.first, next.at < bufferEnd {
            pending.removeFirst()
            let idx = min(frameCount, max(0, Int(((next.at - bufferStart) * sampleRate).rounded())))
            if isWriting, idx > cursor {
                out.writes.append(cursor..<idx)
                framesWritten += Int64(idx - cursor)
            }
            cursor = max(cursor, idx)
            apply(next, frameIndex: cursor, bufferStart: bufferStart, sampleRate: sampleRate, into: &out)
        }
        if isWriting, frameCount > cursor {
            out.writes.append(cursor..<frameCount)
            framesWritten += Int64(frameCount - cursor)
        }
        if isWriting, var seg = currentSegment {
            seg.frameCount = framesWritten - seg.fileFrameOffset
            currentSegment = seg
        }
        return out
    }

    private mutating func apply(_ c: Command, frameIndex: Int, bufferStart: TimeInterval,
                                sampleRate: Double, into out: inout Output) {
        switch c.action {
        case .start, .resume:
            guard !isWriting else { return }
            isWriting = true
            let localStart = bufferStart + Double(frameIndex) / sampleRate
            let seg = RecordingSegment(window: c.window, sharedStart: localStart + clockOffset,
                                       fileFrameOffset: framesWritten, frameCount: 0)
            currentSegment = seg
            out.events.append(.segmentStarted(seg))
        case .pause, .stop:
            if isWriting, let seg = currentSegment {
                isWriting = false
                let length = framesWritten - seg.fileFrameOffset
                currentSegment = nil
                out.events.append(.segmentEnded(window: seg.window, frameCount: length))
            }
            if c.action == .stop {
                pending.removeAll()
                out.events.append(.stopped)
            }
        }
    }
}

/// Transport state machine shared by all devices. Validates commands and derives the
/// recording windows (shared clock) that the owner uses for alignment.
public struct TransportState: Sendable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case idle
        case recording
        case paused
        case stopped
    }

    public private(set) var phase: Phase = .idle
    public private(set) var windows: [RecordingWindow] = []
    public private(set) var take: Int = 0
    /// Shared-clock time of the last start/resume (for the running timer).
    public private(set) var lastStart: TimeInterval?

    public init() {}

    public func canApply(_ action: RecordAction) -> Bool {
        switch (phase, action) {
        case (.idle, .start), (.stopped, .start): return true
        case (.recording, .pause), (.recording, .stop): return true
        case (.paused, .resume), (.paused, .stop): return true
        default: return false
        }
    }

    /// Applies a command (from any device). Returns the window index the command belongs
    /// to, or `nil` if the command is invalid in the current phase (duplicate or stale).
    @discardableResult
    public mutating func apply(_ action: RecordAction, at time: TimeInterval, take: Int) -> Int? {
        guard canApply(action) else { return nil }
        switch action {
        case .start:
            self.take = take
            windows = []
            fallthrough
        case .resume:
            let w = RecordingWindow(index: windows.count, start: time)
            windows.append(w)
            phase = .recording
            lastStart = time
            return w.index
        case .pause, .stop:
            let idx = windows.count - 1
            if phase == .recording, idx >= 0 { windows[idx].end = time }
            phase = action == .pause ? .paused : .stopped
            lastStart = nil
            return max(idx, 0)
        }
    }

    /// Recorded duration up to shared time `now` (excluding pauses).
    public func elapsed(at now: TimeInterval) -> TimeInterval {
        windows.reduce(0) { acc, w in
            let end = w.end ?? (phase == .recording ? now : w.start)
            return acc + max(0, end - w.start)
        }
    }
}
