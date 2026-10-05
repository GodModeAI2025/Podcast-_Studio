#if canImport(AVFAudio) && canImport(AVFoundation)
@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import Foundation
import Observation
import StudioCore
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isBluetooth: Bool
    public var isBuiltIn: Bool
}

public enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case noInput
    case converterUnavailable
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Kein Zugriff auf das Mikrofon. Bitte in den Einstellungen erlauben."
        case .noInput: return "Kein Audio-Eingang verfügbar."
        case .converterUnavailable: return "Audioformat wird nicht unterstützt."
        case .alreadyRecording: return "Es läuft bereits eine Aufnahme."
        }
    }
}

/// Microphone capture (M4): AVAudioSession/AVAudioEngine with voice processing, level
/// metering, and sample-accurate local recording into a crash-safe 48 kHz / 24-bit WAV.
///
/// Threading: UI state lives on the main actor; the input tap runs on the engine's
/// render-notification thread and hands buffers to `TrackRecorder`, which owns the
/// scheduler and the file writer behind its own lock/queue.
@MainActor
@Observable
public final class AudioCaptureEngine {
    public private(set) var meter = LevelMeter()
    public private(set) var isRunning = false
    public private(set) var inputs: [AudioInputDevice] = []
    public private(set) var selectedInputID: String?
    public private(set) var lastError: String?
    /// Microphone mode chosen in Control Center (Standard / Voice Isolation / Wide Spectrum).
    public private(set) var microphoneModeName = ""

    /// Echo cancellation + system mic modes. Required when participants use speakers.
    /// Digital input gain in dB (0...+30). Raises quiet microphones (voice processing on
    /// iPhone often delivers around -45 dBFS RMS) for both the meter and the recording.
    public var inputGainDB: Double = 0 {
        didSet { recorder.setInputGain(dB: inputGainDB) }
    }

    public var voiceProcessingEnabled = true {
        didSet { if oldValue != voiceProcessingEnabled { restartIfRunning() } }
    }

    /// iOS 26: high-quality (non-HFP) recording through AirPods.
    public var bluetoothHighQualityRecording = true {
        didSet { if oldValue != bluetoothHighQualityRecording { restartIfRunning() } }
    }

    public let recorder = TrackRecorder()
    private var engine = AVAudioEngine()
    private var observers: [NSObjectProtocol] = []
    /// Set while an interruption (phone call, Siri) suspended the engine.
    private var interrupted = false
    private var lastStartTime: TimeInterval = 0

    public init() {
        installNotificationObservers()
    }

    // MARK: Permissions & devices

    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func refreshInputs() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        inputs = (session.availableInputs ?? []).map { port in
            AudioInputDevice(id: port.uid, name: port.portName,
                             isBluetooth: port.portType == .bluetoothHFP || port.portType == .bluetoothLE,
                             isBuiltIn: port.portType == .builtInMic)
        }
        selectedInputID = session.preferredInput?.uid ?? session.currentRoute.inputs.first?.uid
        #elseif os(macOS)
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                         mediaType: .audio, position: .unspecified)
        inputs = discovery.devices.map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName,
                             isBluetooth: $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBluetooth),
                             isBuiltIn: $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn))
        }
        if selectedInputID == nil { selectedInputID = AVCaptureDevice.default(for: .audio)?.uniqueID }
        #endif
        microphoneModeName = Self.describe(AVCaptureDevice.activeMicrophoneMode)
    }

    public func selectInput(_ id: String) {
        selectedInputID = id
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if let port = session.availableInputs?.first(where: { $0.uid == id }) {
            try? session.setPreferredInput(port)
        }
        #endif
        restartIfRunning()
    }

    /// Opens the system microphone-mode picker (Voice Isolation / Wide Spectrum).
    public func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    // MARK: Engine lifecycle

    public func start() throws {
        guard !isRunning else { return }
        try configureAudioSession()
        engine = AVAudioEngine()
        let input = engine.inputNode
        #if os(macOS)
        if let uid = selectedInputID { try? Self.setInputDevice(uid: uid, on: input) }
        #endif
        // Voice processing must be toggled before the engine is started; it unlocks the
        // system mic modes and removes the remote participants' voices from our track.
        try input.setVoiceProcessingEnabled(voiceProcessingEnabled)
        if voiceProcessingEnabled {
            // Keep the ducking of other audio (FaceTime) minimal.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // Output node must be part of the graph for voice processing I/O.
            _ = engine.outputNode
            engine.mainMixerNode.outputVolume = 0
        }
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { throw CaptureError.noInput }
        try recorder.prepare(inputFormat: hwFormat)

        let recorder = self.recorder
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { buffer, when in
            recorder.handle(buffer: buffer, time: when)
        }
        recorder.onLevels = { [weak self] samples, duration in
            Task { @MainActor in self?.meter.process(samples, duration: duration) }
        }
        engine.prepare()
        lastStartTime = HostClock.now()
        try engine.start()
        isRunning = true
        lastError = nil
        refreshInputs()
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func restartIfRunning() {
        guard isRunning, !recorder.isRecording else { return }
        stop()
        do { try start() } catch { lastError = error.localizedDescription }
    }

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        options.insert(.allowBluetoothHFP)
        if bluetoothHighQualityRecording {
            // iOS 26: AirPods record with the high-quality (non-HFP) codec when available.
            options.insert(.bluetoothHighQualityRecording)
        }
        try session.setCategory(.playAndRecord, mode: .videoChat, options: options)
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        if let id = selectedInputID, let port = session.availableInputs?.first(where: { $0.uid == id }) {
            try? session.setPreferredInput(port)
        }
        #endif
    }

    // MARK: Interruptions (Loop 5)

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: typeRaw) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverEngine() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInputs() }
        })
        #endif
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            let source = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, source === self.engine else { return }  // ignore offline render engines
                // Enabling voice processing during start() itself triggers a change.
                guard HostClock.now() - self.lastStartTime > 1 else { return }
                self.recoverEngine()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInputs() }
        })
    }

    #if os(iOS)
    private func handleInterruption(typeRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            interrupted = true
            // The recorder keeps the file open; the gap is closed as a segment boundary.
            recorder.suspend(at: HostClock.now())
            isRunning = false
        case .ended:
            guard interrupted else { return }
            interrupted = false
            recoverEngine()
        @unknown default:
            break
        }
    }
    #endif

    /// Restarts the engine after a configuration change / interruption without losing the
    /// recording (a new segment is started in the same window).
    private func recoverEngine() {
        // Close the current segment at the restart point; the next buffer after the
        // restart opens a new one, so the gap is placed correctly on the timeline.
        if recorder.isRecording && !recorder.isSuspended { recorder.suspend(at: HostClock.now()) }
        let wasRecording = recorder.isSuspended
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        do {
            try start()
            if wasRecording { recorder.resumeAfterInterruption(at: HostClock.now()) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func describe(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard: return "Standard"
        case .voiceIsolation: return "Sprachisolation"
        case .wideSpectrum: return "Großes Spektrum"
        @unknown default: return "Unbekannt"
        }
    }

    #if os(macOS)
    /// Points the engine's input unit at a specific Core Audio device.
    private static func setInputDevice(uid: String, on input: AVAudioInputNode) throws {
        var deviceID = AudioDeviceID(0)
        var cfUID = uid as CFString
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        guard status == noErr, deviceID != 0, let unit = input.audioUnit else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
    #endif
}

/// Receives input buffers on the audio thread, converts them to 48 kHz mono Float32,
/// runs the `CaptureScheduler` and writes the selected frames to disk on a serial queue.
public final class TrackRecorder: @unchecked Sendable {
    public static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                   channels: 1, interleaved: false)!

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "podstudio.recorder", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var scheduler = CaptureScheduler()
    private var writer: CrashSafeWAVWriter?
    private var suspendedWindow: Int?
    private var lastWindow = 0

    /// Level callback (samples of the converted buffer, buffer duration).
    public var onLevels: (@Sendable ([Float], TimeInterval) -> Void)?
    /// Segment events, delivered on the recorder queue.
    public var onEvent: (@Sendable (CaptureScheduler.Event) -> Void)?
    /// Write errors (disk full …), delivered on the recorder queue.
    public var onError: (@Sendable (Error) -> Void)?

    public init() {}

    public var isRecording: Bool { lock.withLock { scheduler.isWriting } }
    public var isSuspended: Bool { lock.withLock { suspendedWindow != nil } }
    public var framesWritten: Int64 { lock.withLock { scheduler.framesWritten } }

    func prepare(inputFormat: AVAudioFormat) throws {
        let needsConversion = inputFormat.sampleRate != 48_000 || inputFormat.channelCount != 1
            || inputFormat.commonFormat != .pcmFormatFloat32 || inputFormat.isInterleaved
        var conv: AVAudioConverter?
        if needsConversion {
            guard let c = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else { throw CaptureError.converterUnavailable }
            c.downmix = true
            conv = c
        }
        lock.withLock { converter = conv }
    }

    /// Opens (or re-opens for append) the track file and sets the clock offset.
    public func open(url: URL, clockOffset: TimeInterval, append: Bool) throws {
        let w = try CrashSafeWAVWriter(url: url, format: .studio, flushInterval: 48_000, append: append)
        lock.withLock {
            writer = w
            scheduler = CaptureScheduler(clockOffset: clockOffset, framesWritten: w.framesWritten)
        }
    }

    public func updateClockOffset(_ offset: TimeInterval) {
        lock.withLock { scheduler.clockOffset = offset }
    }

    public func schedule(_ action: RecordAction, atLocal time: TimeInterval, window: Int) {
        lock.withLock {
            lastWindow = window
            scheduler.schedule(.init(action: action, at: time, window: window))
        }
    }

    /// Closes the file once all queued writes are done.
    public func close() throws {
        let w = lock.withLock { () -> CrashSafeWAVWriter? in
            let w = writer
            writer = nil
            return w
        }
        try queue.sync { try w?.close() }
    }

    func suspend(at time: TimeInterval) {
        lock.withLock {
            guard scheduler.isWriting else { return }
            suspendedWindow = scheduler.currentSegment?.window ?? lastWindow
            scheduler.schedule(.init(action: .pause, at: time, window: suspendedWindow!))
        }
    }

    func resumeAfterInterruption(at time: TimeInterval) {
        lock.withLock {
            guard let w = suspendedWindow else { return }
            suspendedWindow = nil
            scheduler.schedule(.init(action: .resume, at: time, window: w))
        }
    }

    private var gainLinear: Float = 1

    /// Digital input gain in dB (0...+30), applied before metering and writing.
    public func setInputGain(dB: Double) {
        let linear = Float(pow(10, max(0, min(30, dB)) / 20))
        lock.withLock { gainLinear = linear }
    }

    /// Audio thread.
    func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let bufferStart = time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime)
            : HostClock.now() - Double(buffer.frameLength) / buffer.format.sampleRate
        guard let mono = convert(buffer), let data = mono.floatChannelData?[0] else { return }
        let n = Int(mono.frameLength)
        var samples = Array(UnsafeBufferPointer(start: data, count: n))
        let gain = lock.withLock { gainLinear }
        if gain != 1 {
            for i in samples.indices { samples[i] = max(-1, min(1, samples[i] * gain)) }
        }
        onLevels?(samples, Double(n) / 48_000)

        let (output, w) = lock.withLock {
            (scheduler.process(bufferStart: bufferStart, frameCount: n, sampleRate: 48_000), writer)
        }
        guard !output.writes.isEmpty || !output.events.isEmpty else { return }
        let onEvent = self.onEvent
        let onError = self.onError
        queue.async {
            do {
                for range in output.writes {
                    try samples[range].withUnsafeBufferPointer { try w?.write(interleaved: $0) }
                }
                if output.events.contains(where: { if case .segmentEnded = $0 { return true } else { return false } }) {
                    try w?.flush()
                }
            } catch {
                onError?(error)
            }
            for e in output.events { onEvent?(e) }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = lock.withLock({ converter }) else { return buffer }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }
}
#endif
