import Foundation
import XCTest
@testable import LAMEKit
import StudioCore

final class MP3EncoderTests: XCTestCase {
    private func tone(seconds: Double) -> [Float] {
        (0..<Int(seconds * 48_000)).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / 48_000)) }
    }

    /// Index of the first MPEG audio frame sync after an optional ID3v2 tag.
    private func firstFrameOffset(_ data: Data) -> Int {
        let b = [UInt8](data)
        if b.count > 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {  // "ID3"
            let size = Int(b[6]) << 21 | Int(b[7]) << 14 | Int(b[8]) << 7 | Int(b[9])
            return 10 + size
        }
        return 0
    }

    func testMonoCBRProducesValidFramesAndExpectedSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        var lastProgress = 0.0
        try MP3Encoder.encodeFile(channels: [tone(seconds: 10)], to: url, settings: .podcastMono,
                                  tags: ID3Tags(title: "Test", artist: "PodStudio")) { lastProgress = $0 }
        XCTAssertEqual(lastProgress, 1)
        let data = try Data(contentsOf: url)
        let o = firstFrameOffset(data)
        XCTAssertGreaterThan(o, 10, "ID3v2 tag written")
        let b = [UInt8](data)
        XCTAssertEqual(b[o], 0xFF)
        XCTAssertEqual(b[o + 1] & 0xE0, 0xE0, "MPEG frame sync")
        // MPEG-1 Layer III, 128 kbps (index 9), 48 kHz (index 1), mono (mode 3)
        XCTAssertEqual((b[o + 1] >> 3) & 0x3, 3, "MPEG-1")
        XCTAssertEqual((b[o + 1] >> 1) & 0x3, 1, "Layer III")
        XCTAssertEqual(b[o + 2] >> 4, 9, "128 kbps")
        XCTAssertEqual((b[o + 2] >> 2) & 0x3, 1, "48 kHz")
        XCTAssertEqual(b[o + 3] >> 6, 3, "mono")
        // 10 s at 128 kbps ≈ 160 kB
        XCTAssertEqual(Double(data.count - o), 160_000, accuracy: 3_000)
    }

    func testStereoAcceptsMonoInput() throws {
        let enc = try MP3Encoder(settings: .podcastStereo)
        var out = try enc.encode([tone(seconds: 1)])
        out += try enc.finish()
        XCTAssertGreaterThan(out.count, 20_000)
        XCTAssertEqual(out.first, 0xFF)
        XCTAssertEqual(out[out.startIndex + 3] >> 6, 1, "joint stereo")
    }

    func testRejectsWrongChannelCount() throws {
        let enc = try MP3Encoder(settings: .podcastMono)
        XCTAssertThrowsError(try enc.encode([tone(seconds: 0.1), tone(seconds: 0.1)]))
    }

    func testInvalidSampleRateThrows() {
        XCTAssertThrowsError(try MP3Encoder(settings: MP3Settings(sampleRate: 12_345)))
    }

    func testVersion() {
        XCTAssertTrue(MP3Encoder.lameVersion.hasPrefix("3.100"))
    }
}
