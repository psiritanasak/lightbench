import XCTest
@testable import PhotoApp

final class EditSliderRowChromeTests: XCTestCase {
    func testShouldReset() {
        XCTAssertFalse(EditSliderRowChrome.shouldReset(value: 0, identity: 0))
        XCTAssertTrue(EditSliderRowChrome.shouldReset(value: 0.1, identity: 0))
        XCTAssertTrue(EditSliderRowChrome.shouldReset(value: 5000, identity: 5500))
    }

    func testShowsResetIconTruthTable() {
        XCTAssertFalse(EditSliderRowChrome.showsResetIcon(isDefault: true, isRowHovered: false))
        XCTAssertTrue(EditSliderRowChrome.showsResetIcon(isDefault: true, isRowHovered: true))
        XCTAssertTrue(EditSliderRowChrome.showsResetIcon(isDefault: false, isRowHovered: false))
        XCTAssertTrue(EditSliderRowChrome.showsResetIcon(isDefault: false, isRowHovered: true))
    }

    func testShowsReadoutOutlineTruthTable() {
        XCTAssertFalse(EditSliderRowChrome.showsReadoutOutline(isHovered: false, isEditing: false))
        XCTAssertTrue(EditSliderRowChrome.showsReadoutOutline(isHovered: true, isEditing: false))
        XCTAssertTrue(EditSliderRowChrome.showsReadoutOutline(isHovered: false, isEditing: true))
        XCTAssertTrue(EditSliderRowChrome.showsReadoutOutline(isHovered: true, isEditing: true))
    }

    func testHistorySummary() {
        XCTAssertEqual(EditSliderRowChrome.historySummary(label: "Exposure"), "Reset Exposure")
    }
}
