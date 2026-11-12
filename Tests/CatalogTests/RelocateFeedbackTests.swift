import XCTest
@testable import PhotoApp

final class RelocateFeedbackTests: XCTestCase {
    func testSingleRelocate() {
        let ok = CatalogModel.relocateOneFeedback(filename: "a.jpg", result: .relocated, accessWarning: nil)
        XCTAssertEqual(ok.kind, .notice, "the sidecar must be moved by hand: read, not a toast")
        XCTAssertEqual(ok.message, "Relocated \"a.jpg\". If it had saved edits, move its sidecar file too to keep them.")
        XCTAssertEqual(ok.title, "Photo Catalog")

        let warned = CatalogModel.relocateOneFeedback(filename: "a.jpg", result: .relocated, accessWarning: "W.")
        XCTAssertEqual(warned.kind, .incomplete)
        XCTAssertTrue(warned.message.hasSuffix(" W."))

        let conflict = CatalogModel.relocateOneFeedback(filename: "a.jpg", result: .conflict, accessWarning: nil)
        XCTAssertEqual(conflict.kind, .error)
        XCTAssertEqual(conflict.message, "Couldn't relocate \"a.jpg\" — a different photo is already catalogued at that location.")

        let failed = CatalogModel.relocateOneFeedback(filename: "a.jpg", result: .failed, accessWarning: "W.")
        XCTAssertEqual(failed.kind, .error)
        XCTAssertEqual(failed.message, "Couldn't relocate \"a.jpg\". W.")
    }

    func testBatchRelocate() {
        func make(_ r: Int, _ m: Int, _ u: Int, _ c: Int, failed: Bool = false, warning: String? = nil) -> Feedback {
            CatalogModel.relocateBatchFeedback(relocated: r, missing: m, unmatched: u, conflicts: c, failed: failed, accessWarning: warning)
        }
        let clean = make(3, 3, 0, 0)
        XCTAssertEqual(clean.kind, .notice)
        XCTAssertEqual(clean.message, "Relocated 3 of 3 photo(s). Move any saved-edit sidecar files too, to keep their edits.")

        let partial = make(2, 4, 1, 1)
        XCTAssertEqual(partial.kind, .incomplete)
        XCTAssertEqual(partial.message, "Relocated 2 of 4 photo(s). 1 not found in that folder. 1 skipped (already catalogued at that location). Move any saved-edit sidecar files too, to keep their edits.")

        XCTAssertEqual(make(1, 1, 0, 0, warning: "W.").kind, .incomplete)
        XCTAssertTrue(make(1, 1, 0, 0, warning: "W.").message.hasSuffix(" W."))
        XCTAssertEqual(make(0, 2, 0, 2).kind, .incomplete)
        XCTAssertEqual(make(0, 2, 0, 2).message, "Relocated 0 of 2 photo(s). 2 skipped (already catalogued at that location).")

        let failed = make(0, 2, 0, 0, failed: true, warning: "W.")
        XCTAssertEqual(failed.kind, .error)
        XCTAssertEqual(failed.message, "Couldn't relocate the selected photos. W.")
    }
}
