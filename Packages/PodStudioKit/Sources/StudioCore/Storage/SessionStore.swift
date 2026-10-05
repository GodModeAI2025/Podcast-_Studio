import Foundation

public struct Marker: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Shared-clock time.
    public var at: TimeInterval
    public var note: String
    public var author: UUID?

    public init(id: UUID = UUID(), at: TimeInterval, note: String, author: UUID? = nil) {
        self.id = id
        self.at = at
        self.note = note
        self.author = author
    }
}

public enum TrackFileFormat: String, Codable, Sendable {
    /// Crash-safe recording file (PCM 48 kHz / 24 bit)
    case wav
    /// Lossless archive after finalisation
    case alac
    case aac
}

public struct TrackInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { participantID }
    public var participantID: UUID
    public var displayName: String
    /// Path relative to the session directory.
    public var relativePath: String
    public var format: TrackFileFormat
    public var sampleRate: Int
    public var channels: Int
    public var frameCount: Int64
    public var segments: [RecordingSegment]
    public var createdAt: Date
    /// While recording, segment times are stamped on the **local** host clock; this is the
    /// latest estimate of (shared − local). It keeps improving during the session, so the
    /// conversion happens as late as possible (upload / mix). `nil` = already shared time.
    public var clockOffset: TimeInterval?

    public init(participantID: UUID, displayName: String, relativePath: String, format: TrackFileFormat,
                sampleRate: Int = 48_000, channels: Int = 1, frameCount: Int64 = 0,
                segments: [RecordingSegment] = [], createdAt: Date = Date()) {
        self.participantID = participantID
        self.displayName = displayName
        self.relativePath = relativePath
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameCount = frameCount
        self.segments = segments
        self.createdAt = createdAt
    }

    public var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }

    /// Segments on the shared session clock.
    public var sharedSegments: [RecordingSegment] {
        guard let offset = clockOffset, offset != 0 else { return segments }
        return segments.map { var s = $0; s.sharedStart += offset; return s }
    }

    /// Copy with segments converted to the shared clock (for delivery to the owner).
    public func resolvedToSharedClock() -> TrackInfo {
        var t = self
        t.segments = sharedSegments
        t.clockOffset = nil
        return t
    }
}

public enum RecordingState: String, Codable, Sendable {
    case idle
    case recording
    case paused
    case finished
    /// Recording was interrupted by a crash and repaired by `RecoveryScanner`.
    case recovered
}

/// `session.json` — everything needed to re-open, deliver and mix a session.
public struct SessionManifest: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var ownerID: UUID
    public var localParticipantID: UUID
    public var participants: [ParticipantInfo]
    public var windows: [RecordingWindow]
    public var markers: [Marker]
    public var state: RecordingState
    public var localTrack: TrackInfo?
    /// Owner only: tracks delivered by participants (and the owner's own).
    public var receivedTracks: [TrackInfo]
    public var scriptRevision: Int
    /// Owner only: CloudKit zone name used for delivery (deleted after mixing).
    public var deliveryZoneName: String?
    /// Share URL of the owner's delivery zone (participants keep it to retry uploads,
    /// e.g. after a crash or when they were offline at the end of the session).
    public var deliveryShareURL: URL?

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), ownerID: UUID,
                localParticipantID: UUID, participants: [ParticipantInfo] = [], windows: [RecordingWindow] = [],
                markers: [Marker] = [], state: RecordingState = .idle, localTrack: TrackInfo? = nil,
                receivedTracks: [TrackInfo] = [], scriptRevision: Int = 0, deliveryZoneName: String? = nil,
                deliveryShareURL: URL? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.ownerID = ownerID
        self.localParticipantID = localParticipantID
        self.participants = participants
        self.windows = windows
        self.markers = markers
        self.state = state
        self.localTrack = localTrack
        self.receivedTracks = receivedTracks
        self.scriptRevision = scriptRevision
        self.deliveryZoneName = deliveryZoneName
        self.deliveryShareURL = deliveryShareURL
    }

    public var isOwner: Bool { ownerID == localParticipantID }
}

/// Local-first storage (M8):
///
///     <root>/Sessions/<UUID>/session.json
///                           script.md
///                           tracks/<participant>.wav|.caf
///                           received/<participant>.caf      (owner)
///                           exports/*.mp3                   (owner)
public struct SessionStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Application Support/PodStudio (excluded from nothing — local only, never synced).
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("PodStudio", isDirectory: true)
    }

    public var sessionsDirectory: URL { root.appendingPathComponent("Sessions", isDirectory: true) }

    public func directory(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func tracksDirectory(for id: UUID) -> URL { directory(for: id).appendingPathComponent("tracks", isDirectory: true) }
    public func receivedDirectory(for id: UUID) -> URL { directory(for: id).appendingPathComponent("received", isDirectory: true) }
    public func exportsDirectory(for id: UUID) -> URL { directory(for: id).appendingPathComponent("exports", isDirectory: true) }
    public func scriptURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("script.md") }
    public func manifestURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("session.json") }

    public func url(for track: TrackInfo, in session: UUID) -> URL {
        directory(for: session).appendingPathComponent(track.relativePath)
    }

    public func create(_ manifest: SessionManifest, script: String = "") throws {
        let fm = FileManager.default
        for dir in [tracksDirectory(for: manifest.id), receivedDirectory(for: manifest.id), exportsDirectory(for: manifest.id)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try save(manifest)
        try saveScript(script, for: manifest.id)
    }

    /// Atomic write (temp file + rename) so a crash never leaves a half-written manifest.
    public func save(_ manifest: SessionManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory(for: manifest.id), withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: manifestURL(for: manifest.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> SessionManifest {
        let decoder = JSONDecoder()
        return try decoder.decode(SessionManifest.self, from: Data(contentsOf: manifestURL(for: id)))
    }

    public func saveScript(_ markdown: String, for id: UUID) throws {
        try Data(markdown.utf8).write(to: scriptURL(for: id), options: .atomic)
    }

    public func loadScript(for id: UUID) -> String {
        (try? String(contentsOf: scriptURL(for: id), encoding: .utf8)) ?? ""
    }

    public func allSessions() -> [SessionManifest] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        return ids.compactMap(UUID.init(uuidString:)).compactMap { try? load($0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }
}

public struct RecoveryResult: Sendable, Equatable {
    public var sessionID: UUID
    public var recoveredFrames: Int64
    public var repairedHeader: Bool
}

/// Finds sessions that were recording when the app died, repairs the WAV header and closes
/// the open segment so the take can be delivered and mixed as usual.
public struct RecoveryScanner: Sendable {
    public let store: SessionStore

    public init(store: SessionStore) {
        self.store = store
    }

    public func scan() -> [RecoveryResult] {
        store.allSessions().compactMap { manifest in
            guard manifest.state == .recording || manifest.state == .paused else { return nil }
            return try? recover(manifest)
        }
    }

    public func recover(_ manifest: SessionManifest) throws -> RecoveryResult {
        var m = manifest
        var frames: Int64 = 0
        var repaired = false
        if var track = m.localTrack, track.format == .wav {
            let url = store.url(for: track, in: m.id)
            if FileManager.default.fileExists(atPath: url.path) {
                repaired = try WAVRepair.repair(url: url) != nil
                let info = try WAVReader.readInfo(url: url)
                frames = info.framesOnDisk
                track.frameCount = frames
                // The last segment's length is only known at pause/stop; derive it from the file.
                if var last = track.segments.last {
                    last.frameCount = max(0, frames - last.fileFrameOffset)
                    track.segments[track.segments.count - 1] = last
                }
                m.localTrack = track
            }
        }
        m.state = .recovered
        try store.save(m)
        return RecoveryResult(sessionID: m.id, recoveredFrames: frames, repairedHeader: repaired)
    }
}
