import Foundation
import XCTest
@testable import StudioCore

final class CaptureSchedulerTests: XCTestCase {
    let sr = 48_000.0

    func testStartsAndStopsOnExactFrame() {
        var s = CaptureScheduler(clockOffset: 100)
        s.schedule(.init(action: .start, at: 10.0105, window: 0))  // frame 504 of 2nd buffer
        s.schedule(.init(action: .stop, at: 10.0305, window: 0))
        // 10 ms buffers (480 frames) starting at t = 10.000
        var written = 0
        var events: [CaptureScheduler.Event] = []
        for b in 0..<5 {
            let out = s.process(bufferStart: 10 + Double(b) * 0.01, frameCount: 480, sampleRate: sr)
            written += out.writes.reduce(0) { $0 + $1.count }
            events += out.events
            if b == 1 { XCTAssertEqual(out.writes, [24..<480]) }
            if b == 3 { XCTAssertEqual(out.writes, [0..<24]) }
        }
        XCTAssertEqual(written, 960)  // exactly 20 ms
        XCTAssertEqual(s.framesWritten, 960)
        guard case .segmentStarted(let seg) = events.first else { return XCTFail() }
        XCTAssertEqual(seg.sharedStart, 110.0105, accuracy: 1e-9)
        XCTAssertEqual(seg.fileFrameOffset, 0)
        XCTAssertEqual(events.dropFirst().first, .segmentEnded(window: 0, frameCount: 960))
        XCTAssertEqual(events.last, .stopped)
        XCTAssertFalse(s.isWriting)
    }

    func testPauseResumeInsideOneBuffer() {
        var s = CaptureScheduler()
        s.schedule(.init(action: .start, at: 0, window: 0))
        s.schedule(.init(action: .pause, at: 0.002, window: 0))   // frame 96
        s.schedule(.init(action: .resume, at: 0.005, window: 1))  // frame 240
        let out = s.process(bufferStart: 0, frameCount: 480, sampleRate: sr)
        XCTAssertEqual(out.writes, [0..<96, 240..<480])
        XCTAssertEqual(out.events.count, 3)
        guard case .segmentStarted(let second) = out.events[2] else { return XCTFail() }
        XCTAssertEqual(second.window, 1)
        XCTAssertEqual(second.fileFrameOffset, 96)
        XCTAssertEqual(s.currentSegment?.frameCount, 240)
    }

    func testLateCommandStartsAtBufferStart() {
        var s = CaptureScheduler()
        s.schedule(.init(action: .start, at: 5, window: 0))  // arrived too late
        let out = s.process(bufferStart: 7, frameCount: 480, sampleRate: sr)
        XCTAssertEqual(out.writes, [0..<480])
        guard case .segmentStarted(let seg) = out.events.first else { return XCTFail() }
        XCTAssertEqual(seg.sharedStart, 7, "segment is stamped with the real start time")
    }

    func testFutureCommandWaits() {
        var s = CaptureScheduler()
        s.schedule(.init(action: .start, at: 1, window: 0))
        let out = s.process(bufferStart: 0, frameCount: 480, sampleRate: sr)
        XCTAssertTrue(out.writes.isEmpty)
        XCTAssertEqual(s.pending.count, 1)
    }
}

final class TransportStateTests: XCTestCase {
    func testWindowsAndValidation() {
        var t = TransportState()
        XCTAssertNil(t.apply(.pause, at: 1, take: 1))
        XCTAssertEqual(t.apply(.start, at: 10, take: 1), 0)
        XCTAssertNil(t.apply(.start, at: 10.1, take: 1), "duplicate start from a second device is ignored")
        XCTAssertEqual(t.apply(.pause, at: 20, take: 1), 0)
        XCTAssertEqual(t.elapsed(at: 25), 10, accuracy: 1e-9)
        XCTAssertEqual(t.apply(.resume, at: 30, take: 1), 1)
        XCTAssertEqual(t.elapsed(at: 35), 15, accuracy: 1e-9)
        XCTAssertEqual(t.apply(.stop, at: 40, take: 1), 1)
        XCTAssertEqual(t.windows, [RecordingWindow(index: 0, start: 10, end: 20), RecordingWindow(index: 1, start: 30, end: 40)])
        XCTAssertEqual(t.phase, .stopped)
        XCTAssertEqual(t.apply(.start, at: 50, take: 2), 0, "new take resets windows")
        XCTAssertEqual(t.windows.count, 1)
    }

    func testStopWhilePaused() {
        var t = TransportState()
        t.apply(.start, at: 0, take: 1)
        t.apply(.pause, at: 5, take: 1)
        t.apply(.stop, at: 9, take: 1)
        XCTAssertEqual(t.windows, [RecordingWindow(index: 0, start: 0, end: 5)])
    }
}
