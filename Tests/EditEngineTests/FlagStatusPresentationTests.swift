import SwiftUI
import XCTest
@testable import PhotoApp

/// Colour carries meaning only for Reject (red) and colour labels: a Pick is the plain light grey, never yellow.
final class FlagStatusPresentationTests: XCTestCase {
    func testPickIsThePlainMarkGreyRejectIsRed() {
        XCTAssertEqual(FlagStatus.picked.tint, Theme.markOn)
        XCTAssertEqual(FlagStatus.rejected.tint, .red)
        XCTAssertNotEqual(FlagStatus.picked.tint, .yellow)
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
