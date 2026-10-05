import Foundation
import XCTest
@testable import StudioCore

final class MarkerExportTests: XCTestCase {
    let windows = [RecordingWindow(index: 0, start: 100, end: 160), RecordingWindow(index: 1, start: 300, end: nil)]

    func testPositionsSkipPauses() {
        XCTAssertEqual(MarkerExport.timelinePosition(of: 130, windows: windows), 30)
        XCTAssertNil(MarkerExport.timelinePosition(of: 200, windows: windows), "inside the pause")
        XCTAssertEqual(MarkerExport.timelinePosition(of: 310, windows: windows), 70)
        XCTAssertNil(MarkerExport.timelinePosition(of: 50, windows: windows))
    }

    func testFormats() {
        let markers = [Marker(at: 3700 + 300 - 60, note: ""), Marker(at: 130, note: "Versprecher")]
        XCTAssertEqual(MarkerExport.audacityLabels(markers, windows: windows),
                       "30.000000\t30.000000\tVersprecher\n3700.000000\t3700.000000\tMarker 2\n")
        XCTAssertEqual(MarkerExport.chapterList(markers, windows: windows),
                       "00:00:30 Versprecher\n01:01:40 Marker 2\n")
    }
}
