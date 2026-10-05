#if canImport(GroupActivities)
import CoreTransferable
import Foundation
@preconcurrency import GroupActivities

/// The SharePlay activity (M2). Its payload travels with the invitation, so every invitee
/// knows the session ID and who the owner is before the first message arrives.
public struct PodcastSessionActivity: GroupActivity, Transferable, Sendable {
    /// Derived from the bundle ID so every build flavour gets its own activity type.
    public static let activityIdentifier = (Bundle.main.bundleIdentifier ?? "app.podstudio") + ".session"

    public var sessionID: UUID
    public var title: String
    /// App-level participant UUID of the owner (`ParticipantInfo.id`).
    public var ownerID: UUID
    public var ownerName: String

    public init(sessionID: UUID, title: String, ownerID: UUID, ownerName: String) {
        self.sessionID = sessionID
        self.title = title
        self.ownerID = ownerID
        self.ownerName = ownerName
    }

    public var metadata: GroupActivityMetadata {
        var m = GroupActivityMetadata()
        m.title = title
        m.subtitle = "Podcast-Aufnahme mit \(ownerName)"
        m.type = .generic
        m.supportsContinuationOnTV = false
        return m
    }

    /// Lets `ShareLink` start SharePlay via Messages without an existing FaceTime call
    /// (TN3128). Works on iOS and macOS.
    public static var transferRepresentation: some TransferRepresentation {
        GroupActivityTransferRepresentation { activity in activity }
    }
}
#endif
