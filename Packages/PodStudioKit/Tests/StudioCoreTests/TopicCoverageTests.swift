import XCTest
@testable import StudioCore

final class TopicCoverageTests: XCTestCase {
    private let script = ParsedScript(markdown: """
    # Folge 12

    ## Klimawandel und Ozeane
    Meeresspiegel steigt, Korallenriffe sterben, Ozeane versauern.

    ## Energiewende
    Windkraft, Solaranlagen und Stromnetze müssen ausgebaut werden.

    ## Verkehr
    Elektroautos, Bahnverkehr und Radwege in Großstädten.
    """)

    func testCoveredPartialAndForgotten() {
        let spoken = "Der Meeresspiegel steigt weiter und die Korallenriffe sterben, die Ozeane versauern. Beim Verkehr reden wir über Elektroautos."
        let report = TopicCoverage.evaluate(script: script, transcript: spoken, readingSection: 3, elapsed: 20 * 60)
        XCTAssertTrue(report.showsHints)
        let byTitle = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Klimawandel und Ozeane"]?.status, .covered)
        // Reading position (3) passed "Energiewende" (2) without it being mentioned.
        XCTAssertEqual(byTitle["Energiewende"]?.status, .forgotten)
        XCTAssertEqual(report.forgotten.map(\.title), ["Energiewende"])
    }

    func testUpcomingSectionsStayOpen() {
        let report = TopicCoverage.evaluate(script: script, transcript: "Wir starten mit dem Meeresspiegel.", readingSection: 1, elapsed: 5 * 60)
        let energy = report.entries.first { $0.title == "Energiewende" }
        XCTAssertEqual(energy?.status, .open)
        XCTAssertTrue(report.forgotten.isEmpty)
    }

    func testLaterCoveredSectionMakesEarlierOneForgotten() {
        // Reading position never moved (0), but "Verkehr" was clearly covered.
        let spoken = "Elektroautos, Bahnverkehr und Radwege in Großstädten sind das Thema."
        let report = TopicCoverage.evaluate(script: script, transcript: spoken, readingSection: 0, elapsed: 600)
        XCTAssertEqual(report.entries.first { $0.title == "Verkehr" }?.status, .covered)
        XCTAssertEqual(report.entries.first { $0.title == "Energiewende" }?.status, .forgotten)
        XCTAssertEqual(report.entries.first { $0.title == "Klimawandel und Ozeane" }?.status, .forgotten)
    }

    func testNoHintsAfterFortyFiveMinutes() {
        let report = TopicCoverage.evaluate(script: script, transcript: "", readingSection: 3, elapsed: 45 * 60)
        XCTAssertFalse(report.showsHints)
        XCTAssertTrue(report.forgotten.isEmpty)
        XCTAssertNil(report.status(for: 2))
        let before = TopicCoverage.evaluate(script: script, transcript: "", readingSection: 3, elapsed: 45 * 60 - 1)
        XCTAssertFalse(before.forgotten.isEmpty)
    }

    func testStemmingMatchesInflections() {
        let report = TopicCoverage.evaluate(script: script, transcript: "Solaranlage Windkraftwerke Stromnetz ausbauen", readingSection: 3, elapsed: 60)
        XCTAssertEqual(report.entries.first { $0.title == "Energiewende" }?.status, .covered)
    }
}
