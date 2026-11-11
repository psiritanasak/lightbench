import XCTest
@testable import PhotoApp

/// `PasteSettingsModel.feedback(...)`: any skipped or failed photo is an alert; a passing result is a toast.
final class PasteSettingsFeedbackTests: XCTestCase {
    func testClassificationTable() {
        // (written, unchanged, skipped, failed) -> kind
        let table: [(Int, Int, Int, Int, FeedbackKind)] = [
            (3, 0, 0, 0, .done),
            (2, 1, 0, 0, .done),
            (0, 4, 0, 0, .nothingToDo),
            (0, 0, 0, 0, .nothingToDo),
            (2, 0, 1, 0, .incomplete),
            (0, 3, 2, 0, .incomplete),
            (2, 0, 0, 1, .incomplete),
            (0, 0, 0, 2, .incomplete),
            (1, 1, 1, 1, .incomplete),
        ]
        for (written, unchanged, skipped, failed, kind) in table {
            let feedback = PasteSettingsModel.feedback(written: written, unchanged: unchanged, skipped: skipped, failed: failed)
            XCTAssertEqual(feedback.kind, kind, "\(written)/\(unchanged)/\(skipped)/\(failed)")
            XCTAssertEqual(feedback.title, "Paste Settings")
            XCTAssertNil(feedback.action)
            XCTAssertEqual(
                feedback.message,
                PasteSettingsModel.summary(written: written, unchanged: unchanged, skipped: skipped, failed: failed)
            )
            if skipped + failed > 0 { XCTAssertEqual(feedback.presentation, .alert) }
        }
    }
}
