#if canImport(GroupActivities) && canImport(CloudKit) && canImport(AVFAudio)
@preconcurrency import CloudKit
import Foundation
@preconcurrency import GroupActivities
import Observation
import StudioCore
#if canImport(UIKit)
import UIKit
#endif

/// Persisted identity of this device/user inside sessions.
public struct LocalIdentity: Codable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String

    static let key = "podstudio.identity"

    public static func load() -> LocalIdentity {
        if let data = UserDefaults.standard.data(forKey: key),
           let identity = try? JSONDecoder().decode(LocalIdentity.self, from: data) {
            return identity
        }
        let identity = LocalIdentity(id: UUID(), displayName: defaultName)
        identity.save()
        return identity
    }

    public func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static var defaultName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Sprecher:in"
        #endif
    }
}

/// Participant-side upload state.
public enum UploadState: Equatable, Sendable {
    case idle
    case waitingForShare
    case uploading(Double)
    case done
    case failed(String)
}

/// Owns one studio session end to end and is the single source of truth for the UI.
///
/// Message flow (all over the reliable `GroupSessionMessenger`):
/// * join → everybody sends `hello`; the owner answers late joiners with hello, script,
///   reading position, the delivery share URL and — if running — the transport state.
/// * participants run NTP-style `clockPing`/`clockPong` against the owner; the owner's
///   host clock is the shared session clock.
/// * any device may press REC/Pause/Stop: the command is stamped `sharedNow + leadTime`
///   and executed sample-accurately by every device's `CaptureScheduler`.
/// * after Stop: WAV → ALAC, participants upload to the owner's CloudKit zone.
@MainActor
@Observable
public final class StudioController {
    public static let leadTime: TimeInterval = 0.75

    public let store: SessionStore
    public let capture = AudioCaptureEngine()
    public let sharePlay = SharePlayService()
    public let delivery: DeliveryService
    public private(set) var identity: LocalIdentity

    public private(set) var sessions: [SessionManifest] = []
    public private(set) var current: SessionManifest?
    public private(set) var script = ScriptDocument()
    public private(set) var parsedScript = ParsedScript(markdown: "")
    public private(set) var transport = TransportState()
    public private(set) var clock = ClockSynchronizer()
    public private(set) var participants: [UUID: ParticipantInfo] = [:]
    public private(set) var deliveryStatus = DeliveryStatus(expected: [])
    public private(set) var uploadState: UploadState = .idle
    public private(set) var ownerSection = 0
    public var followOwner = true
    public private(set) var exportProgress: (step: String, fraction: Double)?
    public private(set) var exportedFiles: [ExportedFile] = []
    public private(set) var recoveryResults: [RecoveryResult] = []
    public var errorMessage: String?
    public var exportOptions = ExportOptions()

    private var participantIDs: [Participant.ID: UUID] = [:]
    private var shareURL: URL?
    private var sharedZoneID: CKRecordZone.ID?
    private var pendingPings: [UUID: TimeInterval] = [:]
    private var clockTask: Task<Void, Never>?
    private var scriptBroadcast: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var started = false

    public init(store: SessionStore? = nil, cloudContainer: String? = nil) {
        self.store = store ?? SessionStore(root: (try? SessionStore.defaultRoot()) ?? FileManager.default.temporaryDirectory)
        self.delivery = DeliveryService(containerIdentifier: cloudContainer)
        self.identity = LocalIdentity.load()
        wireCallbacks()
    }

    public var isOwner: Bool { current?.isOwner ?? true }
    public var me: ParticipantInfo { ParticipantInfo(id: identity.id, displayName: identity.displayName, isOwner: isOwner) }
    public var sharedNow: TimeInterval { clock.sharedTime(fromLocal: HostClock.now()) }
    public var elapsed: TimeInterval { transport.elapsed(at: sharedNow) }
    public var isInSharePlay: Bool { sharePlay.status == .joined || sharePlay.status == .waiting }
    public var isRecordingActive: Bool { transport.phase == .recording || transport.phase == .paused }

    // MARK: Startup

    public func start() async {
        guard !started else { return }
        started = true
        recoveryResults = RecoveryScanner(store: store).scan()
        reloadSessions()
        Task { await sharePlay.observeSessions() }
        if await AudioCaptureEngine.requestPermission() {
            do { try capture.start() } catch { errorMessage = error.localizedDescription }
        } else {
            errorMessage = CaptureError.permissionDenied.localizedDescription
        }
        await delivery.refreshAccountStatus()
        try? await delivery.ensureSubscription()
    }

    public func rename(_ name: String) {
        identity.displayName = name
        identity.save()
    }

    public func reloadSessions() {
        sessions = store.allSessions()
    }

    // MARK: Sessions

    /// Owner: creates a local session. Invite with `ShareLink(item: activity(for:))`.
    @discardableResult
    public func createSession(title: String) -> SessionManifest {
        let owner = ParticipantInfo(id: identity.id, displayName: identity.displayName, isOwner: true)
        let manifest = SessionManifest(title: title, ownerID: identity.id, localParticipantID: identity.id,
                                       participants: [owner], scriptRevision: 1)
        do {
            try store.create(manifest, script: ScriptDocument.template)
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadSessions()
        open(manifest)
        return manifest
    }

    public func activity(for manifest: SessionManifest) -> PodcastSessionActivity {
        PodcastSessionActivity(sessionID: manifest.id, title: manifest.title, ownerID: manifest.ownerID,
                               ownerName: manifest.participants.first(where: \.isOwner)?.displayName ?? identity.displayName)
    }

    public func open(_ manifest: SessionManifest) {
        // Never switch sessions while this device is recording.
        guard !isRecordingActive || current?.id == manifest.id else { return }
        current = manifest
        let markdown = store.loadScript(for: manifest.id)
        script = ScriptDocument(markdown: markdown, revision: manifest.scriptRevision)
        parsedScript = ParsedScript(markdown: markdown)
        transport = TransportState()
        participants = Dictionary(uniqueKeysWithValues: manifest.participants.map { ($0.id, $0) })
        participants[identity.id] = me
        deliveryStatus = DeliveryStatus(expected: Array(participants.values).sorted { $0.displayName < $1.displayName })
        for track in manifest.receivedTracks { deliveryStatus.update(track.participantID, to: .downloaded) }
        exportedFiles = existingExports(for: manifest)
        uploadState = .idle
        shareURL = manifest.deliveryShareURL
        sharedZoneID = nil
        clock = ClockSynchronizer()
        ownerSection = 0
        if manifest.isOwner, manifest.deliveryZoneName != nil {
            Task { await refreshDelivery() }
        }
    }

    public func close() {
        if isInSharePlay { sharePlay.leave() }
        current = nil
    }

    public func delete(_ manifest: SessionManifest) {
        if current?.id == manifest.id { close() }
        try? store.delete(manifest.id)
        reloadSessions()
    }

    private func save() {
        guard let current else { return }
        do { try store.save(current) } catch { errorMessage = error.localizedDescription }
    }

    private func mutate(_ change: (inout SessionManifest) -> Void) {
        guard var m = current else { return }
        change(&m)
        current = m
        save()
    }

    // MARK: SharePlay wiring

    private func wireCallbacks() {
        sharePlay.onJoin = { [weak self] activity in self?.joined(activity) }
        sharePlay.onMessage = { [weak self] message, participant in self?.handle(message, from: participant) }
        sharePlay.onParticipantsChanged = { [weak self] joined, _ in
            guard let self else { return }
            for p in joined { self.greet(p) }
        }
        sharePlay.onEnd = { [weak self] in
            self?.clockTask?.cancel()
        }
        delivery.onZoneChanged = { [weak self] sessionID in
            guard let self, self.current?.id == sessionID else { return }
            Task { await self.refreshDelivery() }
        }
        capture.recorder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleRecorderEvent(event) }
        }
        capture.recorder.onError = { [weak self] error in
            Task { @MainActor in self?.errorMessage = "Schreibfehler: \(error.localizedDescription)" }
        }
    }

    private func joined(_ activity: PodcastSessionActivity) {
        if let existing = (try? store.load(activity.sessionID)) {
            open(existing)
        } else {
            let owner = ParticipantInfo(id: activity.ownerID, displayName: activity.ownerName, platform: .other, isOwner: true)
            let manifest = SessionManifest(id: activity.sessionID, title: activity.title, ownerID: activity.ownerID,
                                           localParticipantID: identity.id,
                                           participants: [owner, ParticipantInfo(id: identity.id, displayName: identity.displayName, isOwner: false)])
            try? store.create(manifest)
            reloadSessions()
            open(manifest)
        }
        sharePlay.post(.hello(me))
        if isOwner {
            clock = ClockSynchronizer()  // owner clock is the reference
            Task { await prepareDeliveryIfNeeded() }
        } else {
            startClockSync()
        }
    }

    /// Owner → a (new) participant: everything needed to catch up.
    private func greet(_ participant: Participant) {
        Task {
            try? await sharePlay.send(.hello(me), to: participant)
            guard isOwner else { return }
            try? await sharePlay.send(script.message, to: participant)
            try? await sharePlay.send(.scriptPosition(section: ownerSection), to: participant)
            if let url = shareURL, let id = current?.id {
                try? await sharePlay.send(.deliveryShare(url: url, sessionID: id), to: participant)
            }
            // Replay the transport history so the late joiner's window indices match.
            guard transport.phase == .recording || transport.phase == .paused else { return }
            for w in transport.windows {
                let action: RecordAction = w.index == 0 ? .start : .resume
                try? await sharePlay.send(.record(action: action, timestamp: w.start, take: transport.take), to: participant)
                if let end = w.end {
                    try? await sharePlay.send(.record(action: .pause, timestamp: end, take: transport.take), to: participant)
                }
            }
        }
    }

    private func handle(_ message: SessionMessage, from participant: Participant) {
        switch message {
        case .hello(let info):
            participantIDs[participant.id] = info.id
            addParticipant(info)

        case .script(let markdown, let revision):
            guard script.apply(markdown: markdown, revision: revision) else { return }
            parsedScript = ParsedScript(markdown: markdown)
            if let id = current?.id { try? store.saveScript(markdown, for: id) }
            mutate { $0.scriptRevision = revision }

        case .scriptPosition(let section):
            ownerSection = section

        case .record(let action, let timestamp, let take):
            execute(action, at: timestamp, take: take)

        case .marker(let at, let note):
            let author = participantIDs[participant.id]
            mutate { $0.markers.append(Marker(at: at, note: note, author: author)) }

        case .uploadProgress(let id, let fraction):
            deliveryStatus.update(id, to: .uploading(fraction))

        case .trackDelivered(let id):
            deliveryStatus.update(id, to: .available)
            Task { await refreshDelivery() }

        case .clockPing(let id, let sentAt):
            guard isOwner else { return }
            let now = HostClock.now()
            Task { try? await sharePlay.send(.clockPong(id: id, sentAt: sentAt, receivedAt: now, repliedAt: HostClock.now()), to: participant) }

        case .clockPong(let id, let sentAt, let receivedAt, let repliedAt):
            guard pendingPings.removeValue(forKey: id) != nil else { return }
            clock.add(ClockSample(t0: sentAt, t1: receivedAt, t2: repliedAt, t3: HostClock.now()))
            if current?.localTrack != nil, current?.localTrack?.clockOffset != clock.offset {
                let offset = clock.offset
                mutate { $0.localTrack?.clockOffset = offset }
            }

        case .deliveryShare(let url, let sessionID):
            guard sessionID == current?.id, !isOwner else { return }
            shareURL = url
            mutate { $0.deliveryShareURL = url }
            Task { await acceptShare() }
        }
    }

    private func addParticipant(_ info: ParticipantInfo) {
        participants[info.id] = info
        deliveryStatus.addExpected(info)
        mutate { m in
            if let i = m.participants.firstIndex(where: { $0.id == info.id }) {
                m.participants[i] = info
            } else {
                m.participants.append(info)
            }
        }
    }

    private func startClockSync() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                guard let self else { return }
                let id = UUID()
                let t0 = HostClock.now()
                self.pendingPings[id] = t0
                if self.pendingPings.count > 64 { self.pendingPings.removeAll() }
                self.sharePlay.post(.clockPing(id: id, sentAt: t0))
                n += 1
                // burst for a quick first estimate, then keep tracking drift
                try? await Task.sleep(for: .milliseconds(n < 12 ? 400 : 10_000))
            }
        }
    }

    // MARK: Script

    /// Owner edits; broadcast is debounced.
    public func updateScript(_ markdown: String) {
        guard isOwner, script.edit(markdown) != nil else { return }
        parsedScript = ParsedScript(markdown: markdown)
        if let id = current?.id { try? store.saveScript(markdown, for: id) }
        mutate { $0.scriptRevision = script.revision }
        scriptBroadcast?.cancel()
        scriptBroadcast = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.sharePlay.send(self.script.message)
            } catch {
                self.errorMessage = "Drehbuch zu groß für die Synchronisation (max. 250 KB)."
            }
        }
    }

    public func setReadingSection(_ section: Int) {
        ownerSection = section
        if isOwner { sharePlay.post(.scriptPosition(section: section)) }
    }

    // MARK: Transport

    public func canIssue(_ action: RecordAction) -> Bool {
        guard transport.canApply(action) else { return false }
        // A participant's commands are stamped on the shared clock: wait for the first sync.
        if !isOwner, isInSharePlay, !clock.isSynchronized { return false }
        if action == .start, transport.phase == .stopped { return false }  // one take per session (MVP)
        if action == .start, current?.state == .finished || current?.state == .recovered { return false }
        return current != nil
    }

    /// UI action from any participant.
    public func issue(_ action: RecordAction) {
        guard canIssue(action) else { return }
        let at = sharedNow + Self.leadTime
        let take = action == .start ? transport.take + 1 : transport.take
        sharePlay.post(.record(action: action, timestamp: at, take: take))
        execute(action, at: at, take: take)
    }

    public func addMarker(_ note: String = "") {
        let at = sharedNow
        sharePlay.post(.marker(at: at, note: note))
        mutate { $0.markers.append(Marker(at: at, note: note, author: identity.id)) }
    }

    private func execute(_ action: RecordAction, at sharedTime: TimeInterval, take: Int) {
        guard let session = current, let window = transport.apply(action, at: sharedTime, take: take) else { return }
        if action == .start {
            do {
                if !capture.isRunning { try capture.start() }
                let relative = "tracks/\(identity.id.uuidString).wav"
                let url = store.directory(for: session.id).appendingPathComponent(relative)
                // Segments are stamped in local time; see TrackInfo.clockOffset.
                try capture.recorder.open(url: url, clockOffset: 0, append: false)
                let offset = clock.offset
                mutate {
                    $0.localTrack = TrackInfo(participantID: identity.id, displayName: identity.displayName,
                                              relativePath: relative, format: .wav)
                    $0.localTrack?.clockOffset = offset
                    $0.state = .recording
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        capture.recorder.schedule(action, atLocal: clock.localTime(fromShared: sharedTime), window: window)
        mutate {
            $0.windows = transport.windows
            switch action {
            case .start, .resume: $0.state = .recording
            case .pause: $0.state = .paused
            case .stop: break
            }
        }
        if action == .stop {
            finalizeTask = Task { await finishRecording(stopAt: sharedTime) }
        }
    }

    private func handleRecorderEvent(_ event: CaptureScheduler.Event) {
        mutate { m in
            guard var track = m.localTrack else { return }
            switch event {
            case .segmentStarted(let seg):
                track.segments.append(seg)
            case .segmentEnded(let window, let frames):
                if let i = track.segments.lastIndex(where: { $0.window == window }) {
                    track.segments[i].frameCount = frames
                }
            case .stopped:
                break
            }
            m.localTrack = track
        }
    }

    private func finishRecording(stopAt sharedTime: TimeInterval) async {
        // Wait until the stop time has passed and the scheduler closed the segment.
        let localStop = clock.localTime(fromShared: sharedTime)
        while HostClock.now() < localStop + 0.3 || capture.recorder.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        do {
            try capture.recorder.close()
        } catch {
            errorMessage = error.localizedDescription
        }
        guard let session = current, var track = session.localTrack else { return }
        let wav = store.directory(for: session.id).appendingPathComponent(track.relativePath)
        let cafRelative = "tracks/\(identity.id.uuidString).caf"
        let caf = store.directory(for: session.id).appendingPathComponent(cafRelative)
        let frames = capture.recorder.framesWritten
        let ok = await Task.detached { (try? TrackFinalizer.finalize(wav: wav, caf: caf)) ?? false }.value
        track.frameCount = frames
        if ok {
            track.relativePath = cafRelative
            track.format = .alac
        }
        let finished = track
        mutate {
            $0.localTrack = finished
            $0.state = .finished
            $0.windows = transport.windows
        }
        if isOwner {
            mutate { m in
                m.receivedTracks.removeAll { $0.participantID == finished.participantID }
                m.receivedTracks.append(finished.resolvedToSharedClock())
            }
            deliveryStatus.update(identity.id, to: .downloaded)
        } else {
            await uploadLocalTrack()
        }
    }

    // MARK: Delivery — owner

    private func prepareDeliveryIfNeeded() async {
        guard let session = current, isOwner else { return }
        if let url = session.deliveryShareURL, session.deliveryZoneName != nil {
            shareURL = url
            sharePlay.post(.deliveryShare(url: url, sessionID: session.id))
            return
        }
        do {
            let url = try await delivery.prepareDeliveryZone(sessionID: session.id, title: session.title,
                                                             expectedCount: max(participants.count, 1))
            shareURL = url
            mutate {
                $0.deliveryZoneName = DeliverySchema.zoneName(for: session.id)
                $0.deliveryShareURL = url
            }
            sharePlay.post(.deliveryShare(url: url, sessionID: session.id))
        } catch {
            errorMessage = "iCloud-Freigabe fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Fetches the zone, downloads new tracks, updates "X von N".
    public func refreshDelivery() async {
        guard let session = current, session.isOwner, session.deliveryZoneName != nil else { return }
        do {
            let remote = try await delivery.fetchTracks(sessionID: session.id)
            for track in remote where track.info.participantID != identity.id {
                let already = current?.receivedTracks.contains { $0.participantID == track.info.participantID } ?? false
                if already {
                    deliveryStatus.update(track.info.participantID, to: .downloaded)
                    continue
                }
                deliveryStatus.update(track.info.participantID, to: .available)
                let stored = try delivery.store(track, store: store, sessionID: session.id)
                mutate { $0.receivedTracks.append(stored) }
                if participants[stored.participantID] == nil {
                    addParticipant(ParticipantInfo(id: stored.participantID, displayName: stored.displayName,
                                                   platform: .other, isOwner: false))
                }
                deliveryStatus.update(stored.participantID, to: .downloaded)
            }
        } catch {
            errorMessage = "Tracks konnten nicht geladen werden: \(error.localizedDescription)"
        }
    }

    /// Owner: all tracks available for mixing — delivered ones plus the own local track
    /// (which is missing from `receivedTracks` after a crash recovery).
    public var mixableTracks: [TrackInfo] {
        guard let session = current, session.isOwner else { return [] }
        var tracks = session.receivedTracks
        if let own = session.localTrack, !tracks.contains(where: { $0.participantID == own.participantID }) {
            tracks.append(own.resolvedToSharedClock())
        }
        return tracks
    }

    /// Mix + export (owner).
    public func mixAndExport() async {
        guard let session = current, session.isOwner else { return }
        let inputs = mixableTracks.map {
            PostProductionEngine.Input(name: $0.displayName,
                                       fileURL: store.directory(for: session.id).appendingPathComponent($0.relativePath),
                                       segments: $0.sharedSegments)
        }
        let out = store.exportsDirectory(for: session.id)
        let options = exportOptions
        let windows = session.windows
        exportProgress = ("Starte", 0)
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                try await PostProductionEngine.run(inputs: inputs, windows: windows, outputDirectory: out,
                                                   baseName: session.title, options: options) { step, fraction in
                    Task { @MainActor [weak self] in self?.exportProgress = (step, fraction) }
                }
            }.value
            exportedFiles = files
        } catch {
            errorMessage = error.localizedDescription
        }
        exportProgress = nil
    }

    /// Frees the owner's iCloud quota. Local recordings and exports stay.
    public func deleteDeliveryZone() async {
        guard let session = current, session.isOwner else { return }
        do {
            try await delivery.deleteDeliveryZone(sessionID: session.id)
            mutate {
                $0.deliveryZoneName = nil
                $0.deliveryShareURL = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func existingExports(for manifest: SessionManifest) -> [ExportedFile] {
        let dir = store.exportsDirectory(for: manifest.id)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["mp3", "m4a", "wav"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ExportedFile(url: $0, speaker: nil, loudnessLUFS: .nan, peakDB: .nan) }
    }

    // MARK: Delivery — participant

    private func acceptShare() async {
        guard let url = shareURL, sharedZoneID == nil else { return }
        do {
            sharedZoneID = try await delivery.acceptShare(url: url)
            if uploadState == .waitingForShare { await uploadLocalTrack() }
        } catch {
            errorMessage = "iCloud-Freigabe konnte nicht angenommen werden: \(error.localizedDescription)"
        }
    }

    public func uploadLocalTrack() async {
        guard let session = current, !session.isOwner, let localTrack = session.localTrack else { return }
        let track = localTrack.resolvedToSharedClock()
        guard let zoneID = sharedZoneID else {
            uploadState = .waitingForShare
            if shareURL != nil { await acceptShare() }
            return
        }
        let file = store.directory(for: session.id).appendingPathComponent(track.relativePath)
        uploadState = .uploading(0)
        let me = identity.id
        do {
            try await delivery.upload(track: track, fileURL: file, zoneID: zoneID) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    let previous: Double
                    if case .uploading(let p) = self.uploadState { previous = p } else { previous = 0 }
                    self.uploadState = .uploading(fraction)
                    if fraction - previous >= 0.05 || fraction >= 1 {
                        self.sharePlay.post(.uploadProgress(participant: me, fraction: fraction))
                    }
                }
            }
            uploadState = .done
            sharePlay.post(.trackDelivered(participant: me))
        } catch {
            uploadState = .failed(error.localizedDescription)
        }
    }

    // MARK: Push

    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        await delivery.handleRemoteNotification(userInfo)
    }
}
#endif
