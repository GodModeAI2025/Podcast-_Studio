#if canImport(CloudKit)
@preconcurrency import CloudKit
import Foundation
import Observation
import StudioCore

/// CloudKit transfer of the recorded tracks to the owner (M5, AD3).
///
/// * Owner: creates a custom zone `Session-<UUID>` in its **private** database and a
///   zone-wide `CKShare` with `publicPermission = .readWrite`. The share URL is sent to the
///   participants only through the end-to-end encrypted SharePlay messenger.
/// * Participant: accepts the share and saves one `TrackRecord` (with `CKAsset`) into the
///   shared zone via its `sharedCloudDatabase`.
/// * Owner: a `CKDatabaseSubscription` on the private database delivers silent pushes to
///   all of the owner's devices; the app fetches the zone and updates "X von N".
/// * After mixing the owner deletes the zone, which frees the quota. Recordings stay local.
public enum DeliverySchema {
    public static let trackRecordType = "TrackRecord"
    public static let sessionRecordType = "PodcastSession"
    public static let subscriptionID = "podstudio-private-db"

    public enum Field {
        public static let participantID = "participantID"
        public static let displayName = "displayName"
        public static let duration = "duration"
        public static let format = "format"
        public static let sampleRate = "sampleRate"
        public static let channels = "channels"
        public static let frameCount = "frameCount"
        public static let segments = "segments"
        public static let fileAsset = "fileAsset"
        public static let createdAt = "createdAt"
        public static let title = "title"
        public static let expectedCount = "expectedCount"
    }

    public static func zoneName(for sessionID: UUID) -> String { "Session-\(sessionID.uuidString)" }

    public static func sessionID(fromZoneName name: String) -> UUID? {
        guard name.hasPrefix("Session-") else { return nil }
        return UUID(uuidString: String(name.dropFirst("Session-".count)))
    }
}

public struct RemoteTrack: Sendable, Identifiable {
    public var id: UUID { info.participantID }
    public var info: TrackInfo
    public var recordID: CKRecord.ID
    /// Temporary file URL of the downloaded asset (valid until the next fetch).
    public var assetURL: URL?
}

@MainActor
@Observable
public final class DeliveryService {
    public let container: CKContainer
    public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    public private(set) var lastError: String?
    public var retryPolicy = RetryPolicy()

    /// Owner: incremented whenever a push or fetch found changes — views refresh on it.
    public private(set) var changeCounter = 0
    /// Called (owner) when zone changes arrive; argument is the session ID.
    public var onZoneChanged: ((UUID) -> Void)?

    public init(containerIdentifier: String? = nil) {
        container = containerIdentifier.map(CKContainer.init(identifier:)) ?? CKContainer.default()
    }

    public func refreshAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            accountStatus = .couldNotDetermine
            lastError = error.localizedDescription
        }
    }

    // MARK: Owner

    /// Creates zone + zone-wide share. Returns the share URL to distribute via SharePlay.
    public func prepareDeliveryZone(sessionID: UUID, title: String, expectedCount: Int) async throws -> URL {
        let db = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: DeliverySchema.zoneName(for: sessionID))
        _ = try await withRetry { try await db.modifyRecordZones(saving: [zone], deleting: []) }

        let root = CKRecord(recordType: DeliverySchema.sessionRecordType,
                            recordID: CKRecord.ID(recordName: sessionID.uuidString, zoneID: zone.zoneID))
        root[DeliverySchema.Field.title] = title as CKRecordValue
        root[DeliverySchema.Field.expectedCount] = expectedCount as CKRecordValue

        let share = CKShare(recordZoneID: zone.zoneID)
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = "PodStudio: \(title)" as CKRecordValue

        let (results, _) = try await withRetry {
            try await db.modifyRecords(saving: [root, share], deleting: [], savePolicy: .changedKeys)
        }
        guard case .success(let saved)? = results[share.recordID], let savedShare = saved as? CKShare,
              let url = savedShare.url else {
            throw CKError(.internalError)
        }
        try await ensureSubscription()
        return url
    }

    /// Silent push on every change in the owner's private database (all devices).
    public func ensureSubscription() async throws {
        let db = container.privateCloudDatabase
        let subscription = CKDatabaseSubscription(subscriptionID: DeliverySchema.subscriptionID)
        subscription.recordType = DeliverySchema.trackRecordType
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await withRetry { try await db.modifySubscriptions(saving: [subscription], deleting: []) }
    }

    public nonisolated static func isDeliveryNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == DeliverySchema.subscriptionID
    }

    /// Handles a remote notification. Returns `true` if it belonged to PodStudio.
    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard Self.isDeliveryNotification(userInfo) else { return false }
        await refreshAllZones()
        return true
    }

    /// Fetches the list of session zones and notifies `onZoneChanged` for each.
    public func refreshAllZones() async {
        do {
            let zones = try await container.privateCloudDatabase.allRecordZones()
            for zone in zones {
                if let id = DeliverySchema.sessionID(fromZoneName: zone.zoneID.zoneName) {
                    onZoneChanged?(id)
                }
            }
            changeCounter += 1
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fetches all track records in a session zone (owner). Assets are downloaded by
    /// CloudKit to temporary files; copy them with `store(_:into:)`.
    public func fetchTracks(sessionID: UUID) async throws -> [RemoteTrack] {
        let zoneID = CKRecordZone.ID(zoneName: DeliverySchema.zoneName(for: sessionID))
        let db = container.privateCloudDatabase
        var tracks: [RemoteTrack] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await withRetry { try await db.recordZoneChanges(inZoneWith: zoneID, since: token) }
            for (_, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result else { continue }
                let record = modification.record
                guard record.recordType == DeliverySchema.trackRecordType,
                      let info = Self.trackInfo(from: record) else { continue }
                let asset = record[DeliverySchema.Field.fileAsset] as? CKAsset
                tracks.append(RemoteTrack(info: info, recordID: record.recordID, assetURL: asset?.fileURL))
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return tracks
    }

    /// Copies a downloaded asset into the session's `received/` directory.
    public func store(_ track: RemoteTrack, store: SessionStore, sessionID: UUID) throws -> TrackInfo {
        guard let src = track.assetURL else { throw CKError(.assetFileNotFound) }
        let ext = track.info.format == .wav ? "wav" : "caf"
        let relative = "received/\(track.info.participantID.uuidString).\(ext)"
        let dst = store.directory(for: sessionID).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        var info = track.info
        info.relativePath = relative
        return info
    }

    /// Deletes the delivery zone (and with it the share and all assets) after mixing.
    public func deleteDeliveryZone(sessionID: UUID) async throws {
        let zoneID = CKRecordZone.ID(zoneName: DeliverySchema.zoneName(for: sessionID))
        _ = try await withRetry {
            try await self.container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        }
    }

    // MARK: Participant

    /// Accepts the owner's share; returns the zone to upload into.
    public func acceptShare(url: URL) async throws -> CKRecordZone.ID {
        let metadata = try await withRetry { try await self.container.shareMetadata(for: url) }
        if metadata.participantStatus != .accepted {
            _ = try await withRetry { try await self.container.accept(metadata) }
        }
        return metadata.share.recordID.zoneID
    }

    /// Uploads the local track as `TrackRecord` into the owner's shared zone.
    /// `progress` receives 0…1 (CloudKit per-record progress).
    public func upload(track: TrackInfo, fileURL: URL, zoneID: CKRecordZone.ID,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let recordID = CKRecord.ID(recordName: "track-\(track.participantID.uuidString)", zoneID: zoneID)
        let record = CKRecord(recordType: DeliverySchema.trackRecordType, recordID: recordID)
        Self.fill(record, with: track, fileURL: fileURL)
        let db = container.sharedCloudDatabase

        var attempt = 1
        while true {
            do {
                try await Self.save(record, in: db, progress: progress)
                progress(1)
                return
            } catch {
                attempt += 1
                guard Self.isRetryable(error),
                      let delay = retryPolicy.delay(beforeAttempt: attempt, retryAfter: (error as? CKError)?.retryAfterSeconds)
                else { throw error }
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private static func save(_ record: CKRecord, in db: CKDatabase,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .allKeys
            op.qualityOfService = .userInitiated
            op.perRecordProgressBlock = { _, fraction in progress(fraction) }
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            db.add(op)
        }
    }

    // MARK: Record mapping

    static func fill(_ record: CKRecord, with track: TrackInfo, fileURL: URL) {
        typealias F = DeliverySchema.Field
        record[F.participantID] = track.participantID.uuidString as CKRecordValue
        record[F.displayName] = track.displayName as CKRecordValue
        record[F.duration] = track.duration as CKRecordValue
        record[F.format] = track.format.rawValue as CKRecordValue
        record[F.sampleRate] = track.sampleRate as CKRecordValue
        record[F.channels] = track.channels as CKRecordValue
        record[F.frameCount] = track.frameCount as CKRecordValue
        let segments = (try? JSONEncoder().encode(track.segments)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        record[F.segments] = segments as CKRecordValue
        record[F.createdAt] = track.createdAt as CKRecordValue
        record[F.fileAsset] = CKAsset(fileURL: fileURL)
    }

    static func trackInfo(from record: CKRecord) -> TrackInfo? {
        typealias F = DeliverySchema.Field
        guard let idString = record[F.participantID] as? String, let id = UUID(uuidString: idString) else { return nil }
        let segmentsJSON = record[F.segments] as? String ?? "[]"
        let segments = (try? JSONDecoder().decode([RecordingSegment].self, from: Data(segmentsJSON.utf8))) ?? []
        return TrackInfo(
            participantID: id,
            displayName: record[F.displayName] as? String ?? "Gast",
            relativePath: "",
            format: TrackFileFormat(rawValue: record[F.format] as? String ?? "") ?? .alac,
            sampleRate: record[F.sampleRate] as? Int ?? 48_000,
            channels: record[F.channels] as? Int ?? 1,
            frameCount: (record[F.frameCount] as? Int64) ?? Int64(record[F.frameCount] as? Int ?? 0),
            segments: segments,
            createdAt: record[F.createdAt] as? Date ?? Date())
    }

    // MARK: Retry

    static func isRetryable(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return (error as? URLError) != nil }
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .serverResponseLost, .notAuthenticated:
            return true
        default:
            return false
        }
    }

    private func withRetry<T>(_ body: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch {
                attempt += 1
                guard Self.isRetryable(error),
                      let delay = retryPolicy.delay(beforeAttempt: attempt, retryAfter: (error as? CKError)?.retryAfterSeconds)
                else {
                    lastError = error.localizedDescription
                    throw error
                }
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }
}
#endif
