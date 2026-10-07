import XCTest
@testable import PhotoApp

final class RetouchKeyActionTests: XCTestCase {
    private func act(escape: Bool = false, delete: Bool = false, selected: Bool, armed: Bool) -> RetouchKeyAction {
        RetouchKeyAction.action(isEscape: escape, isDelete: delete, hasSelection: selected, isArmed: armed)
    }

    func testDeleteRemovesTheSelectedSpotOnlyWhenOneIsSelected() {
        XCTAssertEqual(act(delete: true, selected: true, armed: true), .deleteSelected)
        XCTAssertEqual(act(delete: true, selected: true, armed: false), .deleteSelected)
        XCTAssertEqual(act(delete: true, selected: false, armed: true), .ignore, "key repeat after the first delete cleared the selection must not delete another spot")
        XCTAssertEqual(act(delete: true, selected: false, armed: false), .ignore)
    }

    func testEscapeDeselectsFirstThenStopsTheTool() {
        XCTAssertEqual(act(escape: true, selected: true, armed: true), .deselect)
        XCTAssertEqual(act(escape: true, selected: true, armed: false), .deselect)
        XCTAssertEqual(act(escape: true, selected: false, armed: true), .disarm)
        XCTAssertEqual(act(escape: true, selected: false, armed: false), .ignore)
    }

    func testOtherKeysAreIgnored() {
        for selected in [true, false] { for armed in [true, false] {
            XCTAssertEqual(act(selected: selected, armed: armed), .ignore)
        } }
    }
}
