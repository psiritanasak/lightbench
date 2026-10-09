import SwiftUI
import XCTest
@testable import PhotoApp

/// The Pick flag is yellow and Reject red (flag states); filled stars use the plain light grey `Theme.markOn`.
final class FlagStatusPresentationTests: XCTestCase {
    func testPickIsYellowRejectIsRed() {
        XCTAssertEqual(FlagStatus.picked.tint, .yellow)
        XCTAssertEqual(FlagStatus.rejected.tint, .red)
    }

    func testTheMarkGreyIsNeutralAndBright() throws {
        let c = try XCTUnwrap(NSColor(Theme.markOn).usingColorSpace(.sRGB))
        XCTAssertEqual(c.redComponent, c.blueComponent, accuracy: 0.001)
        XCTAssertGreaterThan(c.redComponent, 0.8)
    }

    func testColourLabelsKeepTheirColours() {
        XCTAssertEqual(ColorLabel.red.color, .red)
        XCTAssertEqual(ColorLabel.yellow.color, .yellow)
    }
}
