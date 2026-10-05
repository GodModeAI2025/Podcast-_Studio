import Foundation

public enum WAVError: Error, Equatable {
    case cannotOpen(String)
    case notRIFF
    case missingChunk(String)
    case unsupportedFormat(formatTag: UInt16, bits: UInt16)
    case writeFailed
}

public struct WAVFormat: Sendable, Equatable, Codable {
    public var sampleRate: Int
    public var channels: Int
    /// 16 or 24 (integer PCM) or 32 (IEEE float)
    public var bitsPerSample: Int

    public init(sampleRate: Int = 48_000, channels: Int = 1, bitsPerSample: Int = 24) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    public static let studio = WAVFormat(sampleRate: 48_000, channels: 1, bitsPerSample: 24)

    public var isFloat: Bool { bitsPerSample == 32 }
    public var bytesPerFrame: Int { channels * bitsPerSample / 8 }
}

/// Streaming WAV writer that keeps the file playable after a crash.
///
/// The RIFF/data sizes are rewritten and the file is fsync'ed every `flushInterval`
/// frames, so at most that much audio is lost; `WAVRepair` restores the rest from the
/// file length. Not thread-safe — use from one serial queue.
public final class CrashSafeWAVWriter {
    public static let headerSize: UInt64 = 44

    public let url: URL
    public let format: WAVFormat
    public let flushInterval: Int
    public private(set) var framesWritten: Int64 = 0
    private var framesSinceFlush = 0
    private let handle: FileHandle
    private var closed = false
    private var scratch = Data()

    /// Creates a new file, or appends to an existing one (resume after pause).
    public init(url: URL, format: WAVFormat = .studio, flushInterval: Int = 48_000, append: Bool = false) throws {
        guard format.bitsPerSample == 16 || format.bitsPerSample == 24 || format.bitsPerSample == 32 else {
            throw WAVError.unsupportedFormat(formatTag: 0, bits: UInt16(format.bitsPerSample))
        }
        self.url = url
        self.format = format
        self.flushInterval = flushInterval
        let fm = FileManager.default
        if append, fm.fileExists(atPath: url.path) {
            let info = try WAVReader.readInfo(url: url)
            guard info.format == format else { throw WAVError.unsupportedFormat(formatTag: 0, bits: UInt16(format.bitsPerSample)) }
            guard let h = try? FileHandle(forUpdating: url) else { throw WAVError.cannotOpen(url.path) }
            handle = h
            framesWritten = info.frameCount
            try handle.seek(toOffset: info.dataOffset + UInt64(info.frameCount) * UInt64(format.bytesPerFrame))
            try handle.truncate(atOffset: handle.offsetInFile)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: Self.header(format: format, dataBytes: 0)),
                  let h = try? FileHandle(forUpdating: url) else { throw WAVError.cannotOpen(url.path) }
            handle = h
            try handle.seekToEnd()
        }
    }

    deinit {
        if !closed { try? close() }
    }

    /// Appends interleaved Float32 samples (-1…1). Count must be a multiple of `channels`.
    public func write(interleaved samples: UnsafeBufferPointer<Float>) throws {
        let frames = samples.count / format.channels
        guard frames > 0 else { return }
        scratch.removeAll(keepingCapacity: true)
        scratch.reserveCapacity(frames * format.bytesPerFrame)
        switch format.bitsPerSample {
        case 16:
            for s in samples {
                let v = Int16(clamping: Int((max(-1, min(1, s)) * 32767).rounded()))
                withUnsafeBytes(of: v.littleEndian) { scratch.append(contentsOf: $0) }
            }
        case 24:
            for s in samples {
                let v = Int32((Double(max(-1, min(1, s))) * 8_388_607).rounded())
                let u = UInt32(bitPattern: v)
                scratch.append(UInt8(u & 0xFF))
                scratch.append(UInt8((u >> 8) & 0xFF))
                scratch.append(UInt8((u >> 16) & 0xFF))
            }
        default:
            for s in samples {
                withUnsafeBytes(of: s.bitPattern.littleEndian) { scratch.append(contentsOf: $0) }
            }
        }
        try handle.write(contentsOf: scratch)
        framesWritten += Int64(frames)
        framesSinceFlush += frames
        if framesSinceFlush >= flushInterval {
            try flush()
        }
    }

    public func write(interleaved samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try write(interleaved: $0) }
    }

    /// Updates the header sizes and syncs to disk.
    public func flush() throws {
        let end = handle.offsetInFile
        let dataBytes = UInt64(framesWritten) * UInt64(format.bytesPerFrame)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.le32(UInt32(truncatingIfNeeded: 36 + dataBytes)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.le32(UInt32(truncatingIfNeeded: dataBytes)))
        try handle.seek(toOffset: end)
        try handle.synchronize()
        framesSinceFlush = 0
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        try flush()
        try handle.close()
    }

    static func header(format: WAVFormat, dataBytes: UInt32) -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le32(36 &+ dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(le32(16))
        d.append(le16(format.isFloat ? 3 : 1))
        d.append(le16(UInt16(format.channels)))
        d.append(le32(UInt32(format.sampleRate)))
        d.append(le32(UInt32(format.sampleRate * format.bytesPerFrame)))
        d.append(le16(UInt16(format.bytesPerFrame)))
        d.append(le16(UInt16(format.bitsPerSample)))
        d.append(contentsOf: Array("data".utf8))
        d.append(le32(dataBytes))
        return d
    }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

public struct WAVInfo: Sendable, Equatable {
    public var format: WAVFormat
    public var dataOffset: UInt64
    /// Frames according to the header (clamped to the file length).
    public var frameCount: Int64
    /// Frames physically present in the file.
    public var framesOnDisk: Int64
    public var headerConsistent: Bool { frameCount == framesOnDisk }
    public var duration: TimeInterval { Double(framesOnDisk) / Double(format.sampleRate) }
}

public enum WAVReader {
    public static func readInfo(url: URL) throws -> WAVInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw WAVError.cannotOpen(url.path) }
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: 12), head.count == 12,
              String(decoding: head[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: head[8..<12], as: UTF8.self) == "WAVE" else { throw WAVError.notRIFF }

        var format: WAVFormat?
        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let ch = try handle.read(upToCount: 8), ch.count == 8 else { break }
            let id = String(decoding: ch[0..<4], as: UTF8.self)
            let size = UInt64(u32(ch, 4))
            if id == "fmt " {
                guard let f = try handle.read(upToCount: 16), f.count == 16 else { throw WAVError.missingChunk("fmt ") }
                var tag = u16(f, 0)
                let channels = Int(u16(f, 2))
                let rate = Int(u32(f, 4))
                let bits = u16(f, 14)
                if tag == 0xFFFE, size >= 40,  // WAVE_FORMAT_EXTENSIBLE: sub-format GUID at +24
                   let ext = try handle.read(upToCount: 10), ext.count == 10 {
                    tag = u16(ext, 8)
                }
                guard (tag == 1 && (bits == 16 || bits == 24)) || (tag == 3 && bits == 32) else {
                    throw WAVError.unsupportedFormat(formatTag: tag, bits: bits)
                }
                format = WAVFormat(sampleRate: rate, channels: channels, bitsPerSample: Int(bits))
            } else if id == "data" {
                guard let format else { throw WAVError.missingChunk("fmt ") }
                let dataOffset = offset + 8
                let available = (fileSize - dataOffset) / UInt64(format.bytesPerFrame)
                let declared = size / UInt64(format.bytesPerFrame)
                return WAVInfo(format: format, dataOffset: dataOffset,
                               frameCount: Int64(min(declared, available)), framesOnDisk: Int64(available))
            }
            offset += 8 + size + (size & 1)
        }
        throw WAVError.missingChunk("data")
    }

    /// Reads the whole file as de-interleaved Float32. Uses the frames present on disk.
    public static func read(url: URL) throws -> (format: WAVFormat, channels: [[Float]]) {
        let info = try readInfo(url: url)
        let f = info.format
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw WAVError.cannotOpen(url.path) }
        defer { try? handle.close() }
        try handle.seek(toOffset: info.dataOffset)
        let bytes = try handle.read(upToCount: Int(info.framesOnDisk) * f.bytesPerFrame) ?? Data()
        let frames = bytes.count / f.bytesPerFrame
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: f.channels)
        bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            for frame in 0..<frames {
                for c in 0..<f.channels {
                    switch f.bitsPerSample {
                    case 16:
                        let v = Int16(bitPattern: UInt16(p[i]) | UInt16(p[i + 1]) << 8)
                        out[c][frame] = Float(v) / 32768
                        i += 2
                    case 24:
                        var v = Int32(p[i]) | Int32(p[i + 1]) << 8 | Int32(p[i + 2]) << 16
                        if v & 0x800000 != 0 { v |= ~0xFFFFFF }
                        out[c][frame] = Float(v) / 8_388_608
                        i += 3
                    default:
                        let bits = UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
                        out[c][frame] = Float(bitPattern: bits)
                        i += 4
                    }
                }
            }
        }
        return (f, out)
    }

    static func u16(_ d: Data, _ o: Int) -> UInt16 {
        let b = d.startIndex + o
        return UInt16(d[b]) | UInt16(d[b + 1]) << 8
    }

    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        let b = d.startIndex + o
        return UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
    }
}

public enum WAVRepair {
    /// Rewrites RIFF/data sizes from the physical file length (drops a trailing partial
    /// frame). Returns the number of recovered frames, or `nil` if the file was consistent.
    @discardableResult
    public static func repair(url: URL) throws -> Int64? {
        let info = try WAVReader.readInfo(url: url)
        guard !info.headerConsistent else { return nil }
        let dataBytes = UInt64(info.framesOnDisk) * UInt64(info.format.bytesPerFrame)
        guard let handle = try? FileHandle(forUpdating: url) else { throw WAVError.cannotOpen(url.path) }
        defer { try? handle.close() }
        try handle.truncate(atOffset: info.dataOffset + dataBytes)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: CrashSafeWAVWriter.le32(UInt32(truncatingIfNeeded: info.dataOffset - 8 + dataBytes)))
        try handle.seek(toOffset: info.dataOffset - 4)
        try handle.write(contentsOf: CrashSafeWAVWriter.le32(UInt32(truncatingIfNeeded: dataBytes)))
        try handle.synchronize()
        return info.framesOnDisk
    }
}

public enum WAVWriter {
    /// Convenience: writes de-interleaved channels to a new file.
    public static func write(_ channels: [[Float]], to url: URL, format: WAVFormat) throws {
        try? FileManager.default.removeItem(at: url)
        let w = try CrashSafeWAVWriter(url: url, format: format, flushInterval: .max)
        let frames = channels.first?.count ?? 0
        var interleaved = [Float](repeating: 0, count: frames * channels.count)
        for f in 0..<frames {
            for c in channels.indices { interleaved[f * channels.count + c] = channels[c][f] }
        }
        try w.write(interleaved: interleaved)
        try w.close()
    }
}
