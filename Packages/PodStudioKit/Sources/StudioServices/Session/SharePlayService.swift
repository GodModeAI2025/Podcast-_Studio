#if canImport(GroupActivities)
import Combine
import Foundation
@preconcurrency import GroupActivities
import Observation
import StudioCore

/// SharePlay plumbing (M2 + M3): receives `GroupSession`s, joins them, owns the
/// `GroupSessionMessenger` and forwards decoded `SessionMessage`s.
@MainActor
@Observable
public final class SharePlayService {
    public enum Status: Equatable {
        case idle
        case waiting
        case joined
        case invalidated(String)
    }

    public private(set) var status: Status = .idle
    public private(set) var activity: PodcastSessionActivity?
    public private(set) var remoteParticipantCount = 0
    public private(set) var isEligibleForGroupSession = false

    /// Called for every message from another participant.
    public var onMessage: ((SessionMessage, Participant) -> Void)?
    /// Called when a session was joined (new activity) — the app opens/creates the session.
    public var onJoin: ((PodcastSessionActivity) -> Void)?
    /// Called when the set of active participants changed (new joiners need a hello/script).
    public var onParticipantsChanged: ((Set<Participant>, Set<Participant>) -> Void)?
    public var onEnd: (() -> Void)?

    private var session: GroupSession<PodcastSessionActivity>?
    private var messenger: GroupSessionMessenger?
    private var tasks: [Task<Void, Never>] = []
    private var cancellables: Set<AnyCancellable> = []
    private var knownParticipants: Set<Participant> = []
    private let observer = GroupStateObserver()

    public init() {
        isEligibleForGroupSession = observer.isEligibleForGroupSession
        observer.$isEligibleForGroupSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] eligible in self?.isEligibleForGroupSession = eligible }
            .store(in: &cancellables)
    }

    /// Long-running: call once at app start.
    public func observeSessions() async {
        for await session in PodcastSessionActivity.sessions() {
            configure(session)
        }
    }

    /// Starts SharePlay directly when a FaceTime call is active. Without a call, use
    /// `ShareLink(item: activity, …)` in the UI (Messages invitation).
    public func activate(_ activity: PodcastSessionActivity) async -> Bool {
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            do { return try await activity.activate() } catch { return false }
        default:
            return false
        }
    }

    public func leave() {
        session?.leave()
        teardown()
    }

    /// Owner: ends the session for everybody.
    public func end() {
        session?.end()
        teardown()
    }

    public var localParticipant: Participant? { session?.localParticipant }

    // MARK: Sending

    public func send(_ message: SessionMessage) async throws {
        try MessageCodec.validate(message)
        guard let messenger else { return }
        try await messenger.send(message, to: .all)
    }

    public func send(_ message: SessionMessage, to participant: Participant) async throws {
        try MessageCodec.validate(message)
        guard let messenger else { return }
        try await messenger.send(message, to: .only(participant))
    }

    /// Fire-and-forget variant for UI actions; errors are logged.
    public func post(_ message: SessionMessage) {
        Task {
            do { try await send(message) } catch { print("SharePlay send failed: \(error)") }
        }
    }

    // MARK: Session lifecycle

    private func configure(_ session: GroupSession<PodcastSessionActivity>) {
        teardown()
        self.session = session
        self.activity = session.activity
        status = .waiting
        let messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        self.messenger = messenger

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .waiting: self.status = .waiting
                case .joined: self.status = .joined
                case .invalidated(let reason):
                    self.status = .invalidated(reason.localizedDescription)
                    self.onEnd?()
                    self.teardown()
                @unknown default: break
                }
            }
            .store(in: &cancellables)

        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self, let local = self.session?.localParticipant else { return }
                let remote = participants.subtracting([local])
                let joined = remote.subtracting(self.knownParticipants)
                let left = self.knownParticipants.subtracting(remote)
                self.knownParticipants = remote
                self.remoteParticipantCount = remote.count
                if !joined.isEmpty || !left.isEmpty { self.onParticipantsChanged?(joined, left) }
            }
            .store(in: &cancellables)

        tasks.append(Task { [weak self] in
            for await (message, context) in messenger.messages(of: SessionMessage.self) {
                self?.onMessage?(message, context.source)
            }
        })

        session.join()
        onJoin?(session.activity)
    }

    private func teardown() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        cancellables.removeAll()
        // keep the eligibility subscription alive
        observer.$isEligibleForGroupSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] eligible in self?.isEligibleForGroupSession = eligible }
            .store(in: &cancellables)
        messenger = nil
        session = nil
        knownParticipants = []
        remoteParticipantCount = 0
        if case .invalidated = status {} else { status = .idle }
    }
}
#endif
