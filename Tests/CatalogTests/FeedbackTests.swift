import XCTest
@testable import PhotoApp

final class FeedbackTests: XCTestCase {
    func testPresentationPerKind() {
        XCTAssertEqual(FeedbackKind.done.presentation, .toast)
        XCTAssertEqual(FeedbackKind.nothingToDo.presentation, .toast)
        XCTAssertEqual(FeedbackKind.warning.presentation, .toast)
        XCTAssertEqual(FeedbackKind.incomplete.presentation, .alert)
        XCTAssertEqual(FeedbackKind.error.presentation, .alert)
    }

    func testBatchTable() {
        // (written, unchanged, notWritten, caveats) -> kind
        let table: [(Int, Int, Int, Int, FeedbackKind)] = [
            (1, 0, 0, 0, .done), (0, 5, 0, 0, .nothingToDo), (0, 0, 0, 0, .nothingToDo), (3, 2, 0, 0, .done),
            (2, 1, 4, 0, .incomplete), (0, 0, 2, 0, .incomplete), (2, 0, 0, 1, .warning), (0, 0, 0, 1, .warning),
            (1, 0, 1, 1, .incomplete),
        ]
        for (written, unchanged, notWritten, caveats, want) in table {
            XCTAssertEqual(FeedbackClassifier.batch(written: written, unchanged: unchanged, notWritten: notWritten, caveats: caveats), want,
                           "written \(written), unchanged \(unchanged), notWritten \(notWritten), caveats \(caveats)")
        }
    }

    /// Anything not written must reach the user as an alert, whatever the other counts are.
    func testAnythingNotWrittenIsAlwaysAnAlert() {
        for written in 0...3 { for unchanged in 0...3 { for notWritten in 0...3 { for caveats in 0...3 {
            let kind = FeedbackClassifier.batch(written: written, unchanged: unchanged, notWritten: notWritten, caveats: caveats)
            if notWritten > 0 { XCTAssertEqual(kind.presentation, .alert, "\(written) \(unchanged) \(notWritten) \(caveats)") }
        } } } }
    }

    func testErrorHelperAndPresentation() {
        let feedback = Feedback.error("Export", "Nope.")
        XCTAssertEqual(feedback.kind, .error)
        XCTAssertEqual(feedback.presentation, .alert)
        XCTAssertNil(feedback.action)
        XCTAssertEqual(FeedbackAction.revealInFinder([]).title, "Show in Finder")
    }

    // MARK: - Inbox

    private let done = Feedback(kind: .done, title: "Export", message: "Exported 2 photos.")
    private let incomplete = Feedback(kind: .incomplete, title: "Export", message: "Exported 1 photo. 3 failed.")
    private let failure = Feedback.error("Enhance", "Enhance failed.")

    func testInboxPassesAToastOnAndKeepsAnAlert() {
        var inbox = FeedbackInbox()
        XCTAssertEqual(inbox.receive(done), done)
        XCTAssertNil(inbox.presented)
        XCTAssertNil(inbox.receive(incomplete))
        XCTAssertEqual(inbox.presented, incomplete)
    }

    func testALaterToastNeverTakesAnUnreadAlertDown() {
        var inbox = FeedbackInbox()
        _ = inbox.receive(incomplete)
        XCTAssertEqual(inbox.receive(done), done, "the toast is still shown")
        XCTAssertEqual(inbox.presented, incomplete, "and the alert stays until it is acknowledged")
        inbox.acknowledge()
        XCTAssertNil(inbox.presented)
    }

    func testALaterAlertWaitsItsTurn() {
        var inbox = FeedbackInbox()
        _ = inbox.receive(incomplete)
        XCTAssertNil(inbox.receive(failure))
        XCTAssertEqual(inbox.presented, incomplete)
        XCTAssertEqual(inbox.waiting, [failure])
        inbox.presentNext()
        XCTAssertEqual(inbox.presented, incomplete, "nothing replaces an alert that is still up")
        inbox.acknowledge()
        XCTAssertNil(inbox.presented, "closing one alert and showing the next are two steps")
        inbox.presentNext()
        XCTAssertEqual(inbox.presented, failure)
        XCTAssertTrue(inbox.waiting.isEmpty)
        inbox.acknowledge()
        inbox.presentNext()
        XCTAssertNil(inbox.presented)
    }

    func testTheSameAlertTwiceIsAcknowledgedOnce() {
        var inbox = FeedbackInbox()
        _ = inbox.receive(incomplete)
        _ = inbox.receive(incomplete)
        _ = inbox.receive(failure)
        _ = inbox.receive(failure)
        XCTAssertEqual(inbox.waiting, [failure])
    }
}
