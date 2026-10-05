import Foundation

/// Monotonic host clock in seconds.
///
/// On Apple platforms `ProcessInfo.systemUptime` is derived from `mach_absolute_time`, the
/// same time base as `AVAudioTime.hostTime`, so audio buffer timestamps and messenger
/// timestamps can be compared directly.
public enum HostClock {
    public static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// One NTP-style round trip: t0 local send, t1 owner receive, t2 owner reply, t3 local receive.
public struct ClockSample: Sendable, Equatable {
    public var t0: TimeInterval
    public var t1: TimeInterval
    public var t2: TimeInterval
    public var t3: TimeInterval

    public init(t0: TimeInterval, t1: TimeInterval, t2: TimeInterval, t3: TimeInterval) {
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
    }

    /// owner clock − local clock
    public var offset: TimeInterval { ((t1 - t0) + (t2 - t3)) / 2 }
    /// network round-trip time excluding the owner's processing time
    public var roundTrip: TimeInterval { (t3 - t0) - (t2 - t1) }
}

/// Estimates the offset between this device's host clock and the owner's host clock
/// (the shared session clock). Uses the samples with the smallest round-trip time, which
/// are the least affected by asymmetric queueing delays.
public struct ClockSynchronizer: Sendable {
    public private(set) var samples: [ClockSample] = []
    public let maxSamples: Int
    public let bestOf: Int

    public init(maxSamples: Int = 32, bestOf: Int = 3) {
        self.maxSamples = maxSamples
        self.bestOf = bestOf
    }

    public mutating func add(_ sample: ClockSample) {
        guard sample.roundTrip >= 0 else { return }
        samples.append(sample)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }

    public var isSynchronized: Bool { !samples.isEmpty }

    /// owner clock − local clock; 0 when unsynchronised (e.g. on the owner itself).
    public var offset: TimeInterval {
        let best = samples.sorted { $0.roundTrip < $1.roundTrip }.prefix(bestOf)
        guard !best.isEmpty else { return 0 }
        let offsets = best.map(\.offset).sorted()
        return offsets[offsets.count / 2]
    }

    /// Upper bound for the offset error (half of the best round trip).
    public var uncertainty: TimeInterval? {
        samples.map(\.roundTrip).min().map { $0 / 2 }
    }

    public func sharedTime(fromLocal local: TimeInterval) -> TimeInterval { local + offset }
    public func localTime(fromShared shared: TimeInterval) -> TimeInterval { shared - offset }
}
