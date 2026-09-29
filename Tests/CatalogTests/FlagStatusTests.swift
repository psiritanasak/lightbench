import XCTest
@testable import PhotoApp

final class FlagStatusTests: XCTestCase {
    func testToggledPickPicksAnUnflaggedPhoto() {
        XCTAssertEqual(FlagStatus.none.toggledPick, .picked)
    }

    func testToggledPickClearsAPickedPhoto() {
        XCTAssertEqual(FlagStatus.picked.toggledPick, FlagStatus.none)
    }

    /// The non-obvious rule: a Rejected photo clears to unflagged, it does
    /// NOT jump straight to Picked.
    func testToggledPickClearsARejectedPhotoRatherThanPickingIt() {
        XCTAssertEqual(FlagStatus.rejected.toggledPick, FlagStatus.none)
    }

    func testRawValuesMatchTheStoredColumnContract() {
        XCTAssertEqual(FlagStatus.rejected.rawValue, -1)
        XCTAssertEqual(FlagStatus.none.rawValue, 0)
        XCTAssertEqual(FlagStatus.picked.rawValue, 1)
    }
}
