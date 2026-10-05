import Foundation
import XCTest
@testable import StudioCore

final class WAVTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wavtests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip24Bit() throws {
        let url = dir.appendingPathComponent("a.wav")
        let s = sine(frequency: 440, amplitude: 0.8, seconds: 0.5)
        try WAVWriter.write([s], to: url, format: .studio)
        let (format, ch) = try WAVReader.read(url: url)
        XCTAssertEqual(format, .studio)
        XCTAssertEqual(ch[0].count, s.count)
        for i in stride(from: 0, to: s.count, by: 97) {
            XCTAssertEqual(ch[0][i], s[i], accuracy: 2.0 / 8_388_608)
        }
        let info = try WAVReader.readInfo(url: url)
        XCTAssertTrue(info.headerConsistent)
        XCTAssertEqual(info.duration, 0.5, accuracy: 1e-9)
    }

    func testRoundTripStereo16AndFloat() throws {
        for bits in [16, 32] {
            let url = dir.appendingPathComponent("s\(bits).wav")
            let l = sine(frequency: 440, amplitude: 0.5, seconds: 0.1)
            let r = l.map { -$0 }
            try WAVWriter.write([l, r], to: url, format: WAVFormat(sampleRate: 44_100, channels: 2, bitsPerSample: bits))
            let (f, ch) = try WAVReader.read(url: url)
            XCTAssertEqual(f.channels, 2)
            XCTAssertEqual(f.sampleRate, 44_100)
            XCTAssertEqual(ch[1][100], -ch[0][100], accuracy: 1e-4)
            XCTAssertEqual(ch[0][100], l[100], accuracy: bits == 16 ? 1e-4 : 1e-7)
        }
    }

    func testCrashLeavesRepairableFile() throws {
        let url = dir.appendingPathComponent("crash.wav")
        do {
            let w = try CrashSafeWAVWriter(url: url, flushInterval: 4800)
            // 1 s of audio in 10 ms buffers; header is flushed every 100 ms
            for _ in 0..<100 { try w.write(interleaved: [Float](repeating: 0.25, count: 480)) }
            try w.write(interleaved: [Float](repeating: 0.25, count: 100))
            // Simulate a crash: no close(). Leak the writer so deinit does not finalise.
            _ = Unmanaged.passRetained(w)
        }
        let before = try WAVReader.readInfo(url: url)
        XCTAssertEqual(before.framesOnDisk, 48_100)
        XCTAssertEqual(before.frameCount, 48_000, "header reflects the last flush")
        XCTAssertFalse(before.headerConsistent)

        XCTAssertEqual(try WAVRepair.repair(url: url), 48_100)
        let after = try WAVReader.readInfo(url: url)
        XCTAssertTrue(after.headerConsistent)
        XCTAssertNil(try WAVRepair.repair(url: url), "second repair is a no-op")
    }

    func testRepairDropsPartialFrame() throws {
        let url = dir.appendingPathComponent("partial.wav")
        try WAVWriter.write([[Float](repeating: 0.1, count: 10)], to: url, format: .studio)
        let h = try FileHandle(forUpdating: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data([1, 2]))  // 2 of 3 bytes of a frame
        try h.close()
        XCTAssertNil(try WAVRepair.repair(url: url), "partial frame alone keeps header consistent")
        XCTAssertEqual(try WAVReader.read(url: url).channels[0].count, 10)
    }

    func testAppendAfterPause() throws {
        let url = dir.appendingPathComponent("append.wav")
        let w1 = try CrashSafeWAVWriter(url: url)
        try w1.write(interleaved: [Float](repeating: 0.1, count: 1000))
        try w1.close()
        let w2 = try CrashSafeWAVWriter(url: url, append: true)
        XCTAssertEqual(w2.framesWritten, 1000)
        try w2.write(interleaved: [Float](repeating: -0.1, count: 500))
        try w2.close()
        let ch = try WAVReader.read(url: url).channels[0]
        XCTAssertEqual(ch.count, 1500)
        XCTAssertEqual(ch[999], 0.1, accuracy: 1e-6)
        XCTAssertEqual(ch[1000], -0.1, accuracy: 1e-6)
    }

    func testRejectsGarbage() throws {
        let url = dir.appendingPathComponent("garbage.wav")
        try Data("hello world, not a wav".utf8).write(to: url)
        XCTAssertThrowsError(try WAVReader.readInfo(url: url))
    }
}

final class SessionStoreTests: XCTestCase {
    var store: SessionStore!

    override func setUpWithError() throws {
        store = SessionStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: store.root)
    }

    func testCreateLoadList() throws {
        let me = UUID()
        let m = SessionManifest(title: "Folge 1", ownerID: me, localParticipantID: me)
        try store.create(m, script: "# Hallo")
        XCTAssertEqual(try store.load(m.id), m)
        XCTAssertEqual(store.loadScript(for: m.id), "# Hallo")
        XCTAssertEqual(store.allSessions().map(\.id), [m.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.tracksDirectory(for: m.id).path))
        XCTAssertTrue(m.isOwner)
        try store.delete(m.id)
        XCTAssertTrue(store.allSessions().isEmpty)
    }

    func testRecoveryScanRepairsInterruptedRecording() throws {
        let me = UUID()
        var m = SessionManifest(title: "Crash", ownerID: UUID(), localParticipantID: me, state: .recording)
        let track = TrackInfo(participantID: me, displayName: "Ich", relativePath: "tracks/\(me.uuidString).wav", format: .wav,
                              segments: [
                                RecordingSegment(window: 0, sharedStart: 10, fileFrameOffset: 0, frameCount: 24_000),
                                RecordingSegment(window: 1, sharedStart: 50, fileFrameOffset: 24_000, frameCount: 0),
                              ])
        m.localTrack = track
        try store.create(m)

        let w = try CrashSafeWAVWriter(url: store.url(for: track, in: m.id), flushInterval: 48_000)
        try w.write(interleaved: [Float](repeating: 0.2, count: 50_000))  // header flushed at 50 000
        try w.write(interleaved: [Float](repeating: 0.2, count: 10_000))  // not yet flushed
        _ = Unmanaged.passRetained(w)  // crash without close

        // A finished session must not be touched.
        let done = SessionManifest(title: "Done", ownerID: me, localParticipantID: me, state: .finished)
        try store.create(done)

        let results = RecoveryScanner(store: store).scan()
        XCTAssertEqual(results, [RecoveryResult(sessionID: m.id, recoveredFrames: 60_000, repairedHeader: true)])
        let recovered = try store.load(m.id)
        XCTAssertEqual(recovered.state, .recovered)
        XCTAssertEqual(recovered.localTrack?.frameCount, 60_000)
        XCTAssertEqual(recovered.localTrack?.segments.last?.frameCount, 36_000)
        XCTAssertEqual(try store.load(done.id).state, .finished)
        XCTAssertTrue(RecoveryScanner(store: store).scan().isEmpty, "recovery is idempotent")
    }
}
