import Foundation
import XCTest
@testable import StudioCore

final class MessageCodecTests: XCTestCase {
    func testRoundTripAllCases() throws {
        let id = UUID()
        let messages: [SessionMessage] = [
            .hello(ParticipantInfo(id: id, displayName: "Anna", platform: .macOS, isOwner: true)),
            .script(markdown: "# Titel\n\nÄÖÜ ß – „Zitat“ 🎙️", revision: 7),
            .scriptPosition(section: 3),
            .record(action: .start, timestamp: 1234.5678, take: 1),
            .record(action: .pause, timestamp: 1300, take: 1),
            .record(action: .resume, timestamp: 1310, take: 1),
            .record(action: .stop, timestamp: 1400.25, take: 1),
            .marker(at: 42.1, note: "Versprecher"),
            .uploadProgress(participant: id, fraction: 0.5),
            .trackDelivered(participant: id),
            .clockPing(id: id, sentAt: 10),
            .clockPong(id: id, sentAt: 10, receivedAt: 110.01, repliedAt: 110.02),
            .deliveryShare(url: URL(string: "https://www.icloud.com/share/abc#Session")!, sessionID: id),
        ]
        for m in messages {
            let data = try MessageCodec.encode(m)
            XCTAssertEqual(try MessageCodec.decode(data), m)
        }
    }

    func testRecordActionCasesRoundTrip() throws {
        for action in RecordAction.allCases {
            let m = SessionMessage.record(action: action, timestamp: 1, take: 2)
            XCTAssertEqual(try MessageCodec.decode(MessageCodec.encode(m)), m)
        }
    }

    func testPayloadLimit() {
        let big = String(repeating: "x", count: 300 * 1024)
        XCTAssertThrowsError(try MessageCodec.validate(.script(markdown: big, revision: 1))) { error in
            guard case MessageCodecError.payloadTooLarge(let bytes, let limit) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertGreaterThan(bytes, limit)
        }
        XCTAssertNoThrow(try MessageCodec.validate(.script(markdown: String(repeating: "x", count: 100 * 1024), revision: 1)))
    }
}

final class ScriptDocumentTests: XCTestCase {
    func testHighestRevisionWins() {
        var doc = ScriptDocument()
        XCTAssertTrue(doc.apply(markdown: "a", revision: 1))
        XCTAssertTrue(doc.apply(markdown: "c", revision: 3))
        XCTAssertFalse(doc.apply(markdown: "b", revision: 2), "older revision must be ignored")
        XCTAssertFalse(doc.apply(markdown: "c2", revision: 3), "equal revision must be ignored")
        XCTAssertEqual(doc.markdown, "c")
        XCTAssertEqual(doc.revision, 3)
    }

    func testOutOfOrderDeliveryConverges() {
        var a = ScriptDocument()
        var b = ScriptDocument()
        let updates = (1...5).map { ("v\($0)", $0) }
        for u in updates { a.apply(markdown: u.0, revision: u.1) }
        for u in updates.reversed() { b.apply(markdown: u.0, revision: u.1) }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.markdown, "v5")
    }

    func testEditBumpsRevision() {
        var doc = ScriptDocument(markdown: "a", revision: 4)
        XCTAssertEqual(doc.edit("b"), .script(markdown: "b", revision: 5))
        XCTAssertNil(doc.edit("b"), "no-op edits are not broadcast")
        XCTAssertEqual(doc.revision, 5)
    }
}

final class MarkdownScriptTests: XCTestCase {
    func testBlocksAndSections() {
        let md = """
        Vorspann ohne Überschrift

        # Folge 12
        ## Intro
        Hallo **zusammen**,
        heute geht es um *Audio*.

        - Punkt eins
        * Punkt zwei
        1. Erstens
        > Zitat

        ## Outro
        ```
        code # kein heading
        ```
        ---
        """
        let parsed = ParsedScript(markdown: md)
        XCTAssertEqual(parsed.sections.map(\.title), ["Start", "Folge 12", "Intro", "Outro"])
        XCTAssertEqual(parsed.blocks.map(\.kind), [
            .paragraph, .heading(level: 1), .heading(level: 2), .paragraph,
            .bullet, .bullet, .numbered(1), .quote, .heading(level: 2), .code, .rule,
        ])
        XCTAssertEqual(parsed.blocks[3].text, "Hallo **zusammen**, heute geht es um *Audio*.")
        XCTAssertEqual(parsed.blocks[3].section, 2)
        XCTAssertEqual(parsed.blocks[9].text, "code # kein heading")
        XCTAssertEqual(parsed.blocks[9].section, 3)
    }

    func testFirstHeadingIsSectionZero() {
        let parsed = ParsedScript(markdown: ScriptDocument.template)
        XCTAssertEqual(parsed.sections.first?.title, "Neue Folge")
        XCTAssertEqual(parsed.sections.map(\.id), Array(0..<parsed.sections.count))
        XCTAssertEqual(parsed.sections.map(\.title), ["Neue Folge", "Intro", "Teil 1", "Teil 2", "Outro"])
    }

    func testHashWithoutSpaceIsNoHeading() {
        let parsed = ParsedScript(markdown: "#hashtag")
        XCTAssertEqual(parsed.blocks.first?.kind, .paragraph)
    }
}

final class ClockSyncTests: XCTestCase {
    func testOffsetWithSymmetricDelay() {
        // owner clock = local + 100, one-way delay 20 ms
        let s = ClockSample(t0: 10, t1: 110.02, t2: 110.03, t3: 10.05)
        XCTAssertEqual(s.offset, 100, accuracy: 1e-9)
        XCTAssertEqual(s.roundTrip, 0.04, accuracy: 1e-9)
    }

    func testPrefersLowRoundTripSamples() {
        var sync = ClockSynchronizer()
        // good samples: offset 100 ± 1 ms
        sync.add(ClockSample(t0: 0, t1: 100.010, t2: 100.010, t3: 0.020))
        sync.add(ClockSample(t0: 1, t1: 101.011, t2: 101.011, t3: 1.020))
        sync.add(ClockSample(t0: 2, t1: 102.009, t2: 102.009, t3: 2.020))
        // congested samples with asymmetric delay (500 ms outbound)
        for i in 3..<10 {
            let t0 = Double(i)
            sync.add(ClockSample(t0: t0, t1: t0 + 100.5, t2: t0 + 100.5, t3: t0 + 0.52))
        }
        XCTAssertEqual(sync.offset, 100, accuracy: 0.002)
        XCTAssertEqual(sync.uncertainty ?? 1, 0.010, accuracy: 1e-9)
        XCTAssertEqual(sync.localTime(fromShared: sync.sharedTime(fromLocal: 5)), 5, accuracy: 1e-9)
    }

    func testUnsynchronizedIsIdentity() {
        let sync = ClockSynchronizer()
        XCTAssertFalse(sync.isSynchronized)
        XCTAssertEqual(sync.sharedTime(fromLocal: 3), 3)
    }

    func testRejectsNegativeRoundTrip() {
        var sync = ClockSynchronizer()
        sync.add(ClockSample(t0: 10, t1: 0, t2: 50, t3: 11))
        XCTAssertFalse(sync.isSynchronized)
    }
}

final class DeliveryStatusTests: XCTestCase {
    func testCountsAndMonotonicStates() {
        let a = ParticipantInfo(id: UUID(), displayName: "A", isOwner: true)
        let b = ParticipantInfo(id: UUID(), displayName: "B", isOwner: false)
        let c = ParticipantInfo(id: UUID(), displayName: "C", isOwner: false)
        var status = DeliveryStatus(expected: [a, b, c])
        XCTAssertEqual(status.summary, "0 von 3 Tracks da")
        status.update(a.id, to: .downloaded)
        status.update(b.id, to: .uploading(0.5))
        XCTAssertEqual(status.overallProgress, 0.5, accuracy: 1e-9)
        status.update(b.id, to: .available)
        status.update(b.id, to: .uploading(0.9))  // late message must not regress
        XCTAssertEqual(status.states[b.id], .available)
        XCTAssertEqual(status.summary, "2 von 3 Tracks da")
        XCTAssertFalse(status.isComplete)
        status.update(c.id, to: .available)
        XCTAssertTrue(status.isComplete)
        status.addExpected(b)
        XCTAssertEqual(status.expectedCount, 3)
    }

    func testRetryPolicy() {
        let p = RetryPolicy(baseDelay: 2, maxDelay: 30, maxAttempts: 6)
        XCTAssertEqual(p.delay(beforeAttempt: 1), 0)
        XCTAssertEqual(p.delay(beforeAttempt: 2), 2)
        XCTAssertEqual(p.delay(beforeAttempt: 3), 4)
        XCTAssertEqual(p.delay(beforeAttempt: 6), 30)
        XCTAssertNil(p.delay(beforeAttempt: 7))
        XCTAssertEqual(p.delay(beforeAttempt: 3, retryAfter: 11), 11)
    }
}
