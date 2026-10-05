#if canImport(Speech) && canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech

/// Thread-safe bridge: the audio thread pushes 48 kHz mono buffers, the analyzer reads
/// them as an async sequence in its preferred format.
final class AnalyzerBufferFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var active = false

    func open(target: AVAudioFormat) -> AsyncStream<AnalyzerInput> {
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        lock.withLock {
            continuation = cont
            self.target = target
            converter = nil
        }
        return stream
    }

    func close() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
            converter = nil
            active = false
        }
    }

    func setActive(_ on: Bool) { lock.withLock { active = on } }

    /// Audio thread.
    func push(_ buffer: AVAudioPCMBuffer) {
        let (cont, target, conv, isActive) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, AVAudioFormat?, AVAudioConverter?, Bool) in
            if converter == nil, let target, buffer.format != target {
                converter = AVAudioConverter(from: buffer.format, to: target)
            }
            return (continuation, self.target, converter, active)
        }
        guard isActive, let cont, let target else { return }
        if buffer.format == target {
            cont.yield(AnalyzerInput(buffer: buffer))
            return
        }
        guard let conv else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var provided = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }
}

/// On-device live transcription of this device's own microphone (SpeechAnalyzer).
/// Finished sentences are handed to `onSentence`; nothing leaves the device here.
@MainActor
@Observable
public final class LiveTranscriber {
    public enum State: Equatable {
        case off
        case preparing(String)
        case listening
        case unavailable(String)
    }

    public private(set) var state: State = .off
    /// Text of the sentence being spoken right now (not final yet).
    public private(set) var partial = ""
    public var onSentence: (@MainActor (String) -> Void)?

    private let feed = AnalyzerBufferFeed()
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    public init() {}

    /// Sink for the capture engine's mono 48 kHz buffers.
    public var sink: @Sendable (AVAudioPCMBuffer) -> Void {
        { [feed] buffer in feed.push(buffer) }
    }

    public func pause(_ paused: Bool) { feed.setActive(!paused && state == .listening) }

    public func start(locale: Locale = Locale(identifier: "de-DE")) async {
        guard state == .off || { if case .unavailable = state { return true } else { return false } }() else { return }
        guard SpeechTranscriber.isAvailable else {
            state = .unavailable("Spracherkennung ist auf diesem Gerät nicht verfügbar.")
            return
        }
        state = .preparing("Sprachmodell wird geprüft …")
        do {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                state = .unavailable("Die Sprache Deutsch wird von der Spracherkennung nicht unterstützt.")
                return
            }
            let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                state = .preparing("Sprachmodell wird geladen …")
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                state = .unavailable("Kein passendes Audioformat für die Spracherkennung.")
                return
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            let stream = feed.open(target: format)
            try await analyzer.start(inputSequence: stream)
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let self else { return }
                        if result.isFinal {
                            self.partial = ""
                            if !text.isEmpty { self.onSentence?(text) }
                        } else {
                            self.partial = text
                        }
                    }
                } catch {
                    guard let self else { return }
                    self.state = .unavailable("Spracherkennung beendet: \(error.localizedDescription)")
                }
            }
            state = .listening
            feed.setActive(true)
        } catch {
            state = .unavailable("Spracherkennung nicht verfügbar: \(error.localizedDescription)")
        }
    }

    public func stop() async {
        feed.close()
        resultsTask?.cancel()
        resultsTask = nil
        partial = ""
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        if state == .listening || { if case .preparing = state { return true } else { return false } }() { state = .off }
    }
}
#endif
