import CLAME
import Foundation

/// MP3 export settings (M7). Constant bitrate, 128–192 kbps recommended for speech podcasts.
public struct MP3Settings: Sendable, Equatable, Codable {
    public enum ChannelMode: String, Sendable, Codable, CaseIterable {
        case mono
        case stereo
    }

    public var bitrateKbps: Int
    public var channelMode: ChannelMode
    public var sampleRate: Int
    /// LAME algorithm quality 0 (best, slowest) … 9 (worst). 2 is LAME's "high quality" preset.
    public var quality: Int

    public init(bitrateKbps: Int = 160, channelMode: ChannelMode = .mono, sampleRate: Int = 48_000, quality: Int = 2) {
        self.bitrateKbps = bitrateKbps
        self.channelMode = channelMode
        self.sampleRate = sampleRate
        self.quality = quality
    }

    public static let podcastMono = MP3Settings(bitrateKbps: 128, channelMode: .mono)
    public static let podcastStereo = MP3Settings(bitrateKbps: 192, channelMode: .stereo)
}

public struct ID3Tags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var comment: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, comment: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.comment = comment
    }
}

public enum MP3EncoderError: Error, Equatable {
    case initFailed
    case invalidParameters(code: Int32)
    case encodeFailed(code: Int32)
    case channelCountMismatch(expected: Int, got: Int)
    case writeFailed
}

/// Streaming MP3 encoder backed by LAME. Not thread-safe; use one instance per export.
///
/// Feed de-interleaved Float32 samples (range -1…1) with `encode(_:)`, call `finish()` once.
public final class MP3Encoder {
    public let settings: MP3Settings
    private let gfp: OpaquePointer
    private var finished = false
    private var outBuffer: [UInt8]

    public init(settings: MP3Settings, tags: ID3Tags? = nil) throws {
        guard Self.supportedSampleRates.contains(settings.sampleRate) else {
            throw MP3EncoderError.invalidParameters(code: -1)
        }
        guard let gfp = lame_init() else { throw MP3EncoderError.initFailed }
        self.gfp = gfp
        self.settings = settings
        self.outBuffer = []

        let channels: Int32 = settings.channelMode == .mono ? 1 : 2
        lame_set_num_channels(gfp, channels)
        lame_set_in_samplerate(gfp, Int32(settings.sampleRate))
        lame_set_out_samplerate(gfp, Int32(settings.sampleRate))
        lame_set_mode(gfp, settings.channelMode == .mono ? MONO : JOINT_STEREO)
        lame_set_VBR(gfp, vbr_off)
        lame_set_brate(gfp, Int32(settings.bitrateKbps))
        lame_set_quality(gfp, Int32(max(0, min(9, settings.quality))))
        // Input is already loudness-normalised and peak-limited; never let LAME rescale or
        // filter it on its own.
        lame_set_scale(gfp, 1.0)
        lame_set_bWriteVbrTag(gfp, 0)

        if let tags {
            id3tag_init(gfp)
            id3tag_v2_only(gfp)
            if let t = tags.title { id3tag_set_title(gfp, t) }
            if let a = tags.artist { id3tag_set_artist(gfp, a) }
            if let a = tags.album { id3tag_set_album(gfp, a) }
            if let c = tags.comment { id3tag_set_comment(gfp, c) }
        }

        let rc = lame_init_params(gfp)
        guard rc >= 0 else {
            lame_close(gfp)
            throw MP3EncoderError.invalidParameters(code: rc)
        }
    }

    deinit {
        lame_close(gfp)
    }

    /// Encodes one block. `channels.count` must match the channel mode
    /// (1 for mono, 2 for stereo; a single channel is duplicated for stereo).
    public func encode(_ channels: [[Float]]) throws -> Data {
        precondition(!finished, "encode after finish")
        let expected = settings.channelMode == .mono ? 1 : 2
        guard channels.count == expected || (expected == 2 && channels.count == 1) else {
            throw MP3EncoderError.channelCountMismatch(expected: expected, got: channels.count)
        }
        let frames = channels.first?.count ?? 0
        if frames == 0 { return Data() }
        // Worst case per LAME docs: 1.25 * samples + 7200
        let capacity = frames + frames / 4 + 7200
        if outBuffer.count < capacity { outBuffer = [UInt8](repeating: 0, count: capacity) }

        let left = channels[0]
        let right = channels.count > 1 ? channels[1] : channels[0]
        let written: Int32 = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                outBuffer.withUnsafeMutableBufferPointer { out in
                    lame_encode_buffer_ieee_float(
                        gfp, l.baseAddress, r.baseAddress, Int32(frames),
                        out.baseAddress, Int32(out.count))
                }
            }
        }
        guard written >= 0 else { throw MP3EncoderError.encodeFailed(code: written) }
        return Data(outBuffer[0..<Int(written)])
    }

    /// Flushes the encoder; returns the final MP3 frames.
    public func finish() throws -> Data {
        precondition(!finished, "finish called twice")
        finished = true
        var tail = [UInt8](repeating: 0, count: 7200)
        let written = tail.withUnsafeMutableBufferPointer { lame_encode_flush(gfp, $0.baseAddress, Int32($0.count)) }
        guard written >= 0 else { throw MP3EncoderError.encodeFailed(code: written) }
        return Data(tail[0..<Int(written)])
    }

    /// Encodes complete de-interleaved audio into `url` in blocks of `blockSize` frames.
    /// `progress` is called with values in 0…1.
    public static func encodeFile(
        channels: [[Float]],
        to url: URL,
        settings: MP3Settings,
        tags: ID3Tags? = nil,
        blockSize: Int = 48_000,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let encoder = try MP3Encoder(settings: settings, tags: tags)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { throw MP3EncoderError.writeFailed }
        defer { try? handle.close() }

        let total = channels.first?.count ?? 0
        var start = 0
        while start < total {
            let end = min(total, start + blockSize)
            let block = channels.map { Array($0[start..<end]) }
            try handle.write(contentsOf: try encoder.encode(block))
            start = end
            progress?(Double(start) / Double(max(total, 1)))
        }
        try handle.write(contentsOf: try encoder.finish())
        progress?(1)
    }

    /// MPEG-1/2/2.5 Layer III sample rates (no resampling inside the encoder).
    public static let supportedSampleRates: Set<Int> = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    public static var lameVersion: String {
        String(cString: get_lame_version())
    }
}
