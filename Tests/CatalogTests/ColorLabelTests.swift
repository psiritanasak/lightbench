import XCTest
@testable import PhotoApp

final class ColorLabelTests: XCTestCase {
    func testRawValuesMatchTheStoredColumnContract() {
        XCTAssertEqual(ColorLabel.none.rawValue, 0)
        XCTAssertEqual(ColorLabel.red.rawValue, 1)
        XCTAssertEqual(ColorLabel.yellow.rawValue, 2)
        XCTAssertEqual(ColorLabel.green.rawValue, 3)
        XCTAssertEqual(ColorLabel.blue.rawValue, 4)
        XCTAssertEqual(ColorLabel.purple.rawValue, 5)
    }

    func testKeysMapToLightroomLabelsAndPurpleHasNoKey() {
        XCTAssertEqual(ColorLabel.forKey("6"), .red)
        XCTAssertEqual(ColorLabel.forKey("7"), .yellow)
        XCTAssertEqual(ColorLabel.forKey("8"), .green)
        XCTAssertEqual(ColorLabel.forKey("9"), .blue)
        XCTAssertNil(ColorLabel.forKey("5"))
        XCTAssertNil(ColorLabel.forKey("0"))
        XCTAssertNil(ColorLabel.forKey("p"))
        let keyedLabels = Set("0123456789".compactMap { ColorLabel.forKey($0) })
        XCTAssertEqual(keyedLabels, [.red, .yellow, .green, .blue])
    }

    func testToggledAppliesADifferentLabel() {
        XCTAssertEqual(ColorLabel.none.toggled(to: .red), .red)
        XCTAssertEqual(ColorLabel.blue.toggled(to: .red), .red)
    }

    func testToggledClearsWhenTheSameLabelIsAppliedAgain() {
        XCTAssertEqual(ColorLabel.red.toggled(to: .red), ColorLabel.none)
    }

    func testMenuOrderCoversEveryLabelExactlyOnce() {
        XCTAssertEqual(Set(ColorLabel.menuOrder), Set(ColorLabel.allCases))
        XCTAssertEqual(ColorLabel.menuOrder.count, ColorLabel.allCases.count)
    }
}
