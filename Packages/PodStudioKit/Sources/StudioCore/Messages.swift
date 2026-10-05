import Foundation

/// Recording transport actions, synchronised across all devices (M3).
public enum RecordAction: String, Codable, Sendable, CaseIterable {
    case start
    case pause
    case resume
    case stop
}

public enum DevicePlatform: String, Codable, Sendable {
    case iOS
    case macOS
    case other

    public static var current: DevicePlatform {
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macOS
        #else
        return .other
        #endif
    }
}

/// Identity of a device inside a session. `id` is an app-generated, persisted UUID
/// (`GroupSession` participant IDs are only valid for one session, our IDs travel with
/// the uploaded tracks).
public struct ParticipantInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var platform: DevicePlatform
    public var isOwner: Bool

    public init(id: UUID, displayName: String, platform: DevicePlatform = .current, isOwner: Bool) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.isOwner = isOwner
    }
}

/// All messages exchanged over `GroupSessionMessenger` (`deliveryMode: .reliable`).
///
/// Every payload must stay far below the 256 KB messenger limit (AD5); `MessageCodec`
/// enforces this. Timestamps are on the **shared session clock** (= owner's host clock,
/// see `ClockSynchronizer`).
public enum SessionMessage: Codable, Sendable, Equatable {
    /// Sent by every device after joining, and by the owner in reply to late joiners.
    case hello(ParticipantInfo)
    /// Full script. Highest revision wins (`ScriptDocument.apply`).
    case script(markdown: String, revision: Int)
    /// Owner's reading position (section index) for synchronised auto-scroll.
    case scriptPosition(section: Int)
    /// Transport command, executed by every device at `timestamp` (shared clock).
    case record(action: RecordAction, timestamp: TimeInterval, take: Int)
    case marker(at: TimeInterval, note: String)
    case uploadProgress(participant: UUID, fraction: Double)
    case trackDelivered(participant: UUID)
    /// NTP-style clock sync: participant → owner.
    case clockPing(id: UUID, sentAt: TimeInterval)
    /// Owner → participant.
    case clockPong(id: UUID, sentAt: TimeInterval, receivedAt: TimeInterval, repliedAt: TimeInterval)
    /// Owner → all: CKShare URL of the delivery zone (only ever sent inside the
    /// end-to-end encrypted SharePlay session).
    case deliveryShare(url: URL, sessionID: UUID)
}

public enum MessageCodecError: Error, Equatable {
    case payloadTooLarge(bytes: Int, limit: Int)
}

/// JSON codec with the GroupSessionMessenger size guard.
public enum MessageCodec {
    /// `GroupSessionMessenger` rejects messages above 256 KB. Keep a safety margin for the
    /// framework's own envelope.
    public static let maxPayloadBytes = 250 * 1024

    public static func encode(_ message: SessionMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard data.count <= maxPayloadBytes else {
            throw MessageCodecError.payloadTooLarge(bytes: data.count, limit: maxPayloadBytes)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> SessionMessage {
        try JSONDecoder().decode(SessionMessage.self, from: data)
    }

    /// Validates a message before handing it to the messenger (which does its own Codable
    /// encoding). Returns the encoded size.
    @discardableResult
    public static func validate(_ message: SessionMessage) throws -> Int {
        try encode(message).count
    }
}
