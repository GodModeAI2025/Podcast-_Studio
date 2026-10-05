import Foundation

/// Owner-side "X von N Tracks da" model (M5). Pure value type, fed by CloudKit fetches and
/// `uploadProgress` / `trackDelivered` messages.
public struct DeliveryStatus: Sendable, Equatable {
    public enum TrackState: Sendable, Equatable {
        case waiting
        case uploading(Double)
        /// Record visible in the owner's zone.
        case available
        /// Asset downloaded into the local session directory.
        case downloaded
        case failed(String)
    }

    public private(set) var expected: [ParticipantInfo]
    public private(set) var states: [UUID: TrackState]

    public init(expected: [ParticipantInfo]) {
        self.expected = expected
        self.states = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, TrackState.waiting) })
    }

    public mutating func addExpected(_ participant: ParticipantInfo) {
        guard !expected.contains(where: { $0.id == participant.id }) else { return }
        expected.append(participant)
        states[participant.id] = states[participant.id] ?? .waiting
    }

    /// State transitions never go backwards (a late progress message must not hide a
    /// track that is already available).
    public mutating func update(_ id: UUID, to new: TrackState) {
        let old = states[id] ?? .waiting
        guard Self.rank(new) >= Self.rank(old) else { return }
        states[id] = new
    }

    public var deliveredCount: Int {
        expected.filter { id in
            switch states[id.id] {
            case .available, .downloaded: return true
            default: return false
            }
        }.count
    }

    public var expectedCount: Int { expected.count }
    public var isComplete: Bool { expectedCount > 0 && deliveredCount == expectedCount }

    /// e.g. "2 von 3 Tracks da"
    public var summary: String { "\(deliveredCount) von \(expectedCount) Tracks da" }

    /// Average progress across all expected tracks, 0…1.
    public var overallProgress: Double {
        guard !expected.isEmpty else { return 0 }
        let sum = expected.reduce(0.0) { acc, p in
            switch states[p.id] ?? .waiting {
            case .waiting, .failed: return acc
            case .uploading(let f): return acc + min(max(f, 0), 1)
            case .available, .downloaded: return acc + 1
            }
        }
        return sum / Double(expected.count)
    }

    private static func rank(_ s: TrackState) -> Int {
        switch s {
        case .waiting: return 0
        case .failed: return 1
        case .uploading: return 2
        case .available: return 3
        case .downloaded: return 4
        }
    }
}

/// Exponential back-off for upload retries (Loop 5).
public struct RetryPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var maxAttempts: Int

    public init(baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 300, maxAttempts: Int = 10) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    /// Delay before attempt `n` (1-based); `nil` when attempts are exhausted.
    /// A server-provided `retryAfter` (CKError.retryAfterSeconds) takes precedence.
    public func delay(beforeAttempt n: Int, retryAfter: TimeInterval? = nil) -> TimeInterval? {
        guard n <= maxAttempts else { return nil }
        if let retryAfter { return retryAfter }
        guard n > 1 else { return 0 }
        return min(maxDelay, baseDelay * pow(2, Double(n - 2)))
    }
}
