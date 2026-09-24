import XCTest
@testable import PhotoApp

/// `PasteSettingsModel.summary(written:unchanged:skipped:failed:)` is pure
/// string formatting, pulled out of `performPaste`'s own file-I/O loop
/// specifically so this narrow slice of the batch-paste result is
/// directly testable — the surrounding loop (file reads/writes,
/// `NSOpenPanel` prompting) stays untested by this codebase's own
/// established precedent for `@MainActor`/file-I/O-driven types
/// (`ImageDocumentModel`, `ExportModel`).
final class PasteSettingsModelSummaryTests: XCTestCase {
    func testAllZeroReportsNoPhotos() {
        XCTAssertEqual(
            PasteSettingsModel.summary(written: 0, unchanged: 0, skipped: 0, failed: 0),
            "No photos to paste onto."
        )
    }

    func testWrittenOnlyUsesSingularForOnePhoto() {
        XCTAssertEqual(
            PasteSettingsModel.summary(written: 1, unchanged: 0, skipped: 0, failed: 0),
            "Pasted onto 1 photo."
        )
    }

    func testWrittenOnlyUsesPluralForMultiplePhotos() {
        XCTAssertEqual(
            PasteSettingsModel.summary(written: 3, unchanged: 0, skipped: 0, failed: 0),
            "Pasted onto 3 photos."
        )
    }

    func testEachNonZeroCategoryAppearsInOrder() {
        XCTAssertEqual(
            PasteSettingsModel.summary(written: 2, unchanged: 1, skipped: 4, failed: 1),
            "Pasted onto 2 photos, 1 already matched, 4 skipped, 1 failed."
        )
    }

    /// Pins the exact case a reviewer round caught as a real bug
    /// upstream: a photo that turned out to need no change at all (a true
    /// no-op paste) must be reported as "already matched", never folded
    /// into "Pasted onto N" — this test only pins the FORMATTING side of
    /// that fix (the counting side lives in `performPaste`, untested by
    /// precedent), but a regression here would at least make a wrong
    /// count visibly wrong in the rendered message.
    func testUnchangedOnlyDoesNotClaimAnythingWasPasted() {
        let message = PasteSettingsModel.summary(written: 0, unchanged: 5, skipped: 0, failed: 0)
        XCTAssertFalse(message.contains("Pasted"))
        XCTAssertEqual(message, "5 already matched.")
    }

    func testSkippedOnlyReportsSkippedNotFailed() {
        XCTAssertEqual(
            PasteSettingsModel.summary(written: 0, unchanged: 0, skipped: 2, failed: 0),
            "2 skipped."
        )
    }
}
