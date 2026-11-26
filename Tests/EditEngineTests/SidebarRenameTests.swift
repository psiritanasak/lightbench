import XCTest
@testable import PhotoApp

final class SidebarRenameTests: XCTestCase {
    private func verdict(_ edit: SidebarEdit, _ text: String, original: String = "", others: [String] = []) -> SidebarRenameVerdict {
        SidebarRename.verdict(edit, text: text, original: original, otherNames: others)
    }

    func testEmptyOrBlankCancels() {
        XCTAssertEqual(verdict(.newCollection, ""), .cancel)
        XCTAssertEqual(verdict(.newCollection, "  \n "), .cancel)
        XCTAssertEqual(verdict(.renameCollection(1), "", original: "Trips"), .cancel)
    }

    func testUnchangedNameCancelsWithNoWrite() {
        XCTAssertEqual(verdict(.renameCollection(1), "Trips", original: "Trips"), .cancel)
        XCTAssertEqual(verdict(.renameSmart(1), "  Trips  ", original: "Trips"), .cancel)
    }

    func testCaseOnlyChangeIsARealRename() {
        XCTAssertEqual(verdict(.renameCollection(1), "trips", original: "Trips"), .commit("trips"))
    }

    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(verdict(.newCollection, "  Summer   2024 "), .commit("Summer 2024"))
    }

    func testDuplicateWithinTheSameKindIsInvalid() {
        guard case .invalid(let message) = verdict(.newCollection, "trips", others: ["Trips", "Family"]) else {
            return XCTFail("expected invalid")
        }
        XCTAssertTrue(message.contains("trips"))
        guard case .invalid = verdict(.renameSmart(2), "FIVE STARS", original: "Old", others: ["Five stars"]) else {
            return XCTFail("expected invalid")
        }
    }

    func testANameEqualToAFolderIsAllowedBecauseFoldersAreNotPassedIn() {
        XCTAssertEqual(verdict(.newCollection, "2024", others: ["Trips"]), .commit("2024"))
    }

    func testANewRowWithTheOriginalBlankNeverCancelsAsUnchanged() {
        XCTAssertEqual(verdict(.newSmart, "High ISO"), .commit("High ISO"))
    }
}
