import XCTest
@testable import PhotoApp

final class FolderImportSummaryTests: XCTestCase {
    private func report(_ outcome: FolderImportOutcome, name: String = "f", warning: String? = nil) -> FolderImportReport {
        FolderImportReport(folderName: name, outcome: outcome, accessWarning: warning)
    }

    func testMessagesAreTodaysExactTexts() {
        XCTAssertEqual(FolderImportSummary.message(.imported(ImportResult(inserted: 1, skipped: 0))), "Imported 1 photo.")
        XCTAssertEqual(FolderImportSummary.message(.imported(ImportResult(inserted: 3, skipped: 0))), "Imported 3 photos.")
        XCTAssertEqual(FolderImportSummary.message(.imported(ImportResult(inserted: 2, skipped: 4))), "Imported 2 photos (4 already in catalog).")
        XCTAssertEqual(FolderImportSummary.message(.noPhotos), "No photos found in that folder.")
        XCTAssertEqual(FolderImportSummary.message(.failed("disk full")), "Import failed: disk full")
    }

    func testOneFolderHasNoPrefixAndTheWarningFollowsTheMessage() {
        let one = FolderImportSummary.feedback([report(.imported(ImportResult(inserted: 1, skipped: 0)), warning: "W.")], title: "Photo Catalog")
        XCTAssertEqual(one.message, "Imported 1 photo. W.")
        XCTAssertEqual(one.title, "Photo Catalog")
    }

    func testSeveralFoldersAreNamedAndJoinedByNewlines() {
        let feedback = FolderImportSummary.feedback([
            report(.imported(ImportResult(inserted: 1, skipped: 0)), name: "one"),
            report(.noPhotos, name: "two", warning: "W."),
            report(.failed("x"), name: "three", warning: "ignored"),
        ], title: "Photo Catalog")
        XCTAssertEqual(feedback.message, "one: Imported 1 photo.\ntwo: No photos found in that folder. W.\nthree: Import failed: x")
    }

    func testKinds() {
        let inserted = FolderImportOutcome.imported(ImportResult(inserted: 2, skipped: 0))
        let skipped = FolderImportOutcome.imported(ImportResult(inserted: 0, skipped: 2))
        let table: [([FolderImportReport], FeedbackKind)] = [
            ([report(inserted)], .done),
            ([report(.imported(ImportResult(inserted: 1, skipped: 5)))], .done),
            ([report(skipped)], .nothingToDo),
            ([report(.noPhotos)], .nothingToDo),
            ([report(inserted, warning: "W")], .incomplete),
            ([report(.noPhotos, warning: "W")], .incomplete),
            ([report(inserted), report(.failed("x"))], .incomplete),
            ([report(.failed("x"))], .error),
            ([report(skipped), report(.noPhotos)], .nothingToDo),
        ]
        for (reports, kind) in table {
            XCTAssertEqual(FolderImportSummary.feedback(reports, title: "Photo Catalog").kind, kind, "\(reports)")
        }
    }
}
