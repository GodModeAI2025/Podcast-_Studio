#if canImport(AVFAudio)
@preconcurrency import AVFAudio
import AudioToolbox
import Foundation
import LAMEKit
import StudioCore

public struct ExportOptions: Sendable, Equatable {
    public var mp3: MP3Settings = .podcastMono
    public var loudness: LoudnessTarget = .podcast
    public var voice: VoiceChainSettings = .podcast
    /// Additional AAC/M4A export next to the MP3s.
    public var alsoAAC = false
    /// Additional 24-bit WAV export (for editing in a DAW).
    public var alsoWAV = false

    public init() {}
}

public struct ExportedFile: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var speaker: String?   // nil = mix
    public var loudnessLUFS: Double
    public var peakDB: Double
}

public enum PostProductionError: Error, LocalizedError {
    case noTracks
    case cannotRead(URL, Error)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noTracks: return "Keine Tracks zum Mischen vorhanden."
        case .cannotRead(let url, let e): return "\(url.lastPathComponent) kann nicht gelesen werden: \(e.localizedDescription)"
        case .renderFailed(let s): return "Rendering fehlgeschlagen: \(s)"
        }
    }
}

/// Owner-side post-production (M6 + M7):
///
/// 1. import every track (ALAC/WAV/AAC) and convert to 48 kHz mono Float32,
/// 2. place it on the common timeline (`TimelineAligner`, REC windows + segments),
/// 3. per speaker: AVAudioEngine **offline manual rendering** through
///    high-pass 80 Hz → mud cut → presence EQ (`AVAudioUnitEQ`) → Apple DynamicsProcessor,
/// 4. loudness normalisation to ~-16 LUFS + peak limiting (`LoudnessNormalizer`),
/// 5. sum mix (normalised again), 6. MP3 via LAME (+ optional AAC / WAV).
public enum PostProductionEngine {
    public static let sampleRate = 48_000.0
    public static let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                 channels: 1, interleaved: false)!

    public struct Input: Sendable {
        public var name: String
        public var fileURL: URL
        public var segments: [RecordingSegment]

        public init(name: String, fileURL: URL, segments: [RecordingSegment]) {
            self.name = name
            self.fileURL = fileURL
            self.segments = segments
        }
    }

    public static func run(
        inputs: [Input],
        windows: [RecordingWindow],
        outputDirectory: URL,
        baseName: String,
        options: ExportOptions = ExportOptions(),
        progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }
    ) async throws -> [ExportedFile] {
        guard !inputs.isEmpty else { throw PostProductionError.noTracks }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 1 + 2: import & align
        let allSegments = inputs.flatMap(\.segments)
        let aligner = TimelineAligner(windows: windows, sampleRate: sampleRate)
        var speakers: [SpeakerInput] = []
        for (i, input) in inputs.enumerated() {
            progress("Importiere \(input.name)", Double(i) / Double(inputs.count) * 0.2)
            let samples = try readMono48k(input.fileURL)
            let placed: [Float]
            if windows.isEmpty || input.segments.isEmpty {
                placed = samples  // solo recording or legacy file: no alignment info
            } else {
                placed = aligner.render(fileSamples: samples, segments: input.segments, allSegments: allSegments)
            }
            speakers.append(SpeakerInput(name: input.name, samples: placed))
        }
        let length = speakers.map(\.samples.count).max() ?? 0
        for i in speakers.indices where speakers[i].samples.count < length {
            speakers[i].samples += [Float](repeating: 0, count: length - speakers[i].samples.count)
        }

        // 3–5: processing
        progress("Optimiere Stimmen", 0.25)
        let voice = options.voice
        let result = PostProductionPipeline.run(speakers: speakers, sampleRate: sampleRate, target: options.loudness) { samples in
            do {
                samples = try renderVoiceChain(samples, settings: voice)
            } catch {
                // Fall back to the identical pure-Swift chain.
                VoiceChain.process(&samples, sampleRate: sampleRate, settings: voice)
            }
        }

        // 6: export
        var files: [ExportedFile] = []
        var mp3 = options.mp3
        mp3.sampleRate = Int(sampleRate)
        let outputs: [(String?, [Float], NormalizationReport)] =
            result.speakers.map { ($0.name, $0.samples, $0.report) } + [(nil, result.mix, result.mixReport)]
        for (i, (speaker, samples, report)) in outputs.enumerated() {
            let base = sanitize(baseName)
            let stem = speaker.map { "\(base) - \(sanitize($0))" } ?? "\(base) - Mix"
            progress("Exportiere \(speaker ?? "Mix")", 0.6 + 0.4 * Double(i) / Double(outputs.count))
            let url = outputDirectory.appendingPathComponent("\(stem).mp3")
            try MP3Encoder.encodeFile(channels: [samples], to: url, settings: mp3,
                                      tags: ID3Tags(title: speaker ?? baseName, artist: speaker, album: baseName,
                                                    comment: "PodStudio"))
            files.append(ExportedFile(url: url, speaker: speaker, loudnessLUFS: report.outputLUFS, peakDB: report.outputPeakDB))
            if options.alsoAAC {
                let m4a = outputDirectory.appendingPathComponent("\(stem).m4a")
                try writeAAC(samples, to: m4a)
                files.append(ExportedFile(url: m4a, speaker: speaker, loudnessLUFS: report.outputLUFS, peakDB: report.outputPeakDB))
            }
            if options.alsoWAV {
                let wav = outputDirectory.appendingPathComponent("\(stem).wav")
                try WAVWriter.write([samples], to: wav, format: .studio)
                files.append(ExportedFile(url: wav, speaker: speaker, loudnessLUFS: report.outputLUFS, peakDB: report.outputPeakDB))
            }
        }
        progress("Fertig", 1)
        return files
    }

    // MARK: Import

    /// Reads any Core Audio file and converts it to 48 kHz mono Float32.
    public static func readMono48k(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw PostProductionError.cannotRead(url, error) }
        let inFormat = file.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else {
            throw PostProductionError.renderFailed("buffer")
        }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * sampleRate / inFormat.sampleRate) + 1024)

        if inFormat.sampleRate == sampleRate && inFormat.channelCount == 1 {
            while file.framePosition < file.length {
                try file.read(into: inBuffer, frameCount: chunk)
                guard inBuffer.frameLength > 0, let d = inBuffer.floatChannelData?[0] else { break }
                out.append(contentsOf: UnsafeBufferPointer(start: d, count: Int(inBuffer.frameLength)))
            }
            return out
        }

        guard let converter = AVAudioConverter(from: inFormat, to: monoFormat) else {
            throw PostProductionError.renderFailed("converter \(inFormat)")
        }
        converter.downmix = true
        let outCapacity = AVAudioFrameCount(Double(chunk) * sampleRate / inFormat.sampleRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: outCapacity) else {
            throw PostProductionError.renderFailed("buffer")
        }
        nonisolated(unsafe) var readError: Error?
        while true {
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { packets, inputStatus in
                if file.framePosition >= file.length {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: min(chunk, packets))
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let d = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: d, count: Int(outBuffer.frameLength)))
            }
            if let readError { throw PostProductionError.cannotRead(url, readError) }
            if status == .error { throw PostProductionError.renderFailed(error?.localizedDescription ?? "convert") }
            if status == .endOfStream { break }
        }
        return out
    }

    // MARK: AVAudioEngine offline voice chain

    /// EQ + dynamics via AVAudioEngine manual rendering (offline, faster than real time).
    public static func renderVoiceChain(_ samples: [Float], settings: VoiceChainSettings) throws -> [Float] {
        guard !samples.isEmpty else { return samples }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let hp = eq.bands[0]
        hp.filterType = .highPass
        hp.frequency = Float(settings.highPassHz)
        hp.bypass = false
        let mud = eq.bands[1]
        mud.filterType = .parametric
        mud.frequency = Float(settings.mudHz)
        mud.gain = Float(settings.mudGainDB)
        mud.bandwidth = 1.0  // octaves
        mud.bypass = false
        let presence = eq.bands[2]
        presence.filterType = .parametric
        presence.frequency = Float(settings.presenceHz)
        presence.gain = Float(settings.presenceGainDB)
        presence.bandwidth = 1.5
        presence.bypass = false

        let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        let tree = dynamics.auAudioUnit.parameterTree
        func set(_ id: AudioUnitParameterID, _ value: Double) {
            tree?.parameter(withAddress: AUParameterAddress(id))?.value = AUValue(value)
        }
        set(kDynamicsProcessorParam_Threshold, settings.compressorThresholdDB)
        // DynamicsProcessor has no ratio parameter: headroom = dB above threshold that
        // map to 0 dBFS output. Approximate the configured ratio over a 20 dB range.
        set(kDynamicsProcessorParam_HeadRoom, max(0.1, 20 / settings.compressorRatio))
        set(kDynamicsProcessorParam_AttackTime, settings.compressorAttack)
        set(kDynamicsProcessorParam_ReleaseTime, settings.compressorRelease)
        set(kDynamicsProcessorParam_ExpansionRatio, 1)

        engine.attach(player)
        engine.attach(eq)
        engine.attach(dynamics)
        engine.connect(player, to: eq, format: monoFormat)
        engine.connect(eq, to: dynamics, format: monoFormat)
        engine.connect(dynamics, to: engine.mainMixerNode, format: monoFormat)

        let maxFrames: AVAudioFrameCount = 8192
        try engine.enableManualRenderingMode(.offline, format: monoFormat, maximumFrameCount: maxFrames)
        try engine.start()
        defer {
            player.stop()
            engine.stop()
        }

        guard let input = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let render = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw PostProductionError.renderFailed("buffer")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        let latency = Int((dynamics.auAudioUnit.latency + eq.auAudioUnit.latency) * sampleRate)
        let total = samples.count + latency
        var out: [Float] = []
        out.reserveCapacity(total)
        while engine.manualRenderingSampleTime < AVAudioFramePosition(total) {
            let remaining = AVAudioFrameCount(AVAudioFramePosition(total) - engine.manualRenderingSampleTime)
            let status = try engine.renderOffline(min(maxFrames, remaining), to: render)
            switch status {
            case .success:
                if let d = render.floatChannelData?[0] {
                    out.append(contentsOf: UnsafeBufferPointer(start: d, count: Int(render.frameLength)))
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw PostProductionError.renderFailed("renderOffline")
            @unknown default:
                throw PostProductionError.renderFailed("renderOffline status")
            }
        }
        // Remove processing latency so the timeline stays aligned.
        return Array(out.dropFirst(latency).prefix(samples.count))
    }

    // MARK: AAC

    static func writeAAC(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try writeChunks(samples, to: file)
    }

    static func writeChunks(_ samples: [Float], to file: AVAudioFile) throws {
        let chunk = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            i += n
        }
    }

    public static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return name.components(separatedBy: bad).joined(separator: "_")
    }
}

/// Converts the crash-safe WAV into the persisted ALAC file (M4/M8, "ALAC persistiert").
public enum TrackFinalizer {
    public static func convertToALAC(wav: URL, caf: URL) throws {
        let source = try AVAudioFile(forReading: wav)
        try? FileManager.default.removeItem(at: caf)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: source.fileFormat.sampleRate,
            AVNumberOfChannelsKey: source.fileFormat.channelCount,
            AVEncoderBitDepthHintKey: 24,
        ]
        let dest = try AVAudioFile(forWriting: caf, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 65_536) else { return }
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try dest.write(from: buffer)
        }
    }

    /// Verifies the ALAC file has the same length as the WAV before the WAV is deleted.
    public static func finalize(wav: URL, caf: URL) throws -> Bool {
        try convertToALAC(wav: wav, caf: caf)
        let a = try AVAudioFile(forReading: wav).length
        let b = try AVAudioFile(forReading: caf).length
        guard a == b else { return false }
        try FileManager.default.removeItem(at: wav)
        return true
    }
}
#endif
