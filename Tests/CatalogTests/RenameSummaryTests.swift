import XCTest
@testable import PhotoApp

final class RenameSummaryTests: XCTestCase {
    func testRenamedIsAToastWithTodaysText() {
        let one = RenameSummary.renamed(count: 1)
        XCTAssertEqual(one.kind, .done)
        XCTAssertEqual(one.title, "Rename")
        XCTAssertEqual(one.message, "Renamed 1 photo. Use Undo Rename to put the names back.")
        XCTAssertEqual(RenameSummary.renamed(count: 3).message, "Renamed 3 photos. Use Undo Rename to put the names back.")
        XCTAssertEqual(RenameSummary.renamed(count: 3).presentation, .toast)
        XCTAssertNil(RenameSummary.renamed(count: 3).action)
    }

    func testRestoredIsAToast() {
        XCTAssertEqual(RenameSummary.restored(count: 1).message, "Restored 1 photo to their previous names.")
        XCTAssertEqual(RenameSummary.restored(count: 2).message, "Restored 2 photos to their previous names.")
        XCTAssertEqual(RenameSummary.restored(count: 2).kind, .done)
        XCTAssertEqual(RenameSummary.restored(count: 2).presentation, .toast)
    }

    func testEveryFailureIsAnAlert() {
        let failure = RenameSummary.failure("Select the photos to rename first.")
        XCTAssertEqual(failure.kind, .error)
        XCTAssertEqual(failure.presentation, .alert)
        XCTAssertEqual(failure.title, "Rename")
        XCTAssertEqual(failure.message, "Select the photos to rename first.")
    }
}
