import XCTest
@testable import PhotoApp

final class HistogramDisplayModeTests: XCTestCase {
    func testNextCyclesAndReturnsToTheStart() {
        var mode = HistogramDisplayMode.luminance
        XCTAssertEqual(mode.next, .rgb)
        XCTAssertEqual(HistogramDisplayMode.rgb.next, .luminance)
        for _ in 0..<HistogramDisplayMode.allCases.count { mode = mode.next }
        XCTAssertEqual(mode, .luminance)
    }

    func testChannelsMapping() {
        XCTAssertEqual(HistogramDisplayMode.luminance.channels, .luminanceOnly)
        XCTAssertEqual(HistogramDisplayMode.rgb.channels, .allChannels)
    }
}
