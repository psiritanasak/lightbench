import XCTest
@testable import PhotoApp

final class FeedbackTests: XCTestCase {
    func testPresentationPerKind() {
        XCTAssertEqual(FeedbackKind.done.presentation, .toast)
        XCTAssertEqual(FeedbackKind.nothingToDo.presentation, .toast)
        XCTAssertEqual(FeedbackKind.warning.presentation, .toast)
        XCTAssertEqual(FeedbackKind.incomplete.presentation, .alert)
        XCTAssertEqual(FeedbackKind.error.presentation, .alert)
        XCTAssertEqual(FeedbackKind.notice.presentation, .alert)
    }

    func testNoticeHelperIsAnAlertKindWithItsAction() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let notice = Feedback.notice("Catalog Backup", "Backed up.", action: .revealInFinder([url]))
        XCTAssertEqual(notice.kind, .notice)
        XCTAssertEqual(notice.presentation, .alert)
        XCTAssertEqual(notice.action, .revealInFinder([url]))
        XCTAssertNil(Feedback.notice("t", "m").action)
    }

    func testTheClassifierNeverReturnsANotice() {
        for written in 0...2 {
            for unchanged in 0...2 {
                for notWritten in 0...2 {
                    for caveats in 0...2 {
                        let kind = FeedbackClassifier.batch(written: written, unchanged: unchanged, notWritten: notWritten, caveats: caveats)
                        XCTAssertNotEqual(kind, .notice)
                    }
                }
            }
        }
    }

    func testInboxKeepsANotice() {
        var inbox = FeedbackInbox()
        XCTAssertNil(inbox.receive(Feedback.notice("Rename", "Read this.")))
        XCTAssertEqual(inbox.presented?.kind, .notice)
    }

    func testReceiveAllReturnsTheToastsInOrderAndKeepsTheAlerts() {
        var inbox = FeedbackInbox()
        let toast1 = Feedback(kind: .done, title: "A", message: "1")
        let toast2 = Feedback(kind: .warning, title: "B", message: "2")
        let alertA = Feedback.error("C", "a")
        let alertB = Feedback.notice("D", "b")
        let toasts = inbox.receive(all: [toast1, alertA, toast2, alertB])
        XCTAssertEqual(toasts, [toast1, toast2])
        XCTAssertEqual(inbox.presented, alertA)
        XCTAssertEqual(inbox.waiting, [alertB])
        XCTAssertEqual(inbox.receive(all: []), [])
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
        inbox.acknowledge(incomplete)
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
        inbox.acknowledge(incomplete)
        XCTAssertNil(inbox.presented, "closing one alert and showing the next are two steps")
        inbox.presentNext()
        XCTAssertEqual(inbox.presented, failure)
        XCTAssertTrue(inbox.waiting.isEmpty)
        inbox.acknowledge(failure)
        inbox.presentNext()
        XCTAssertNil(inbox.presented)
    }

    func testANewAlertCannotJumpTheQueueBetweenAcknowledgeAndPresentNext() {
        var inbox = FeedbackInbox()
        let third = Feedback.error("Paste Settings", "Third.")
        _ = inbox.receive(incomplete)
        _ = inbox.receive(failure)
        inbox.acknowledge(incomplete)
        XCTAssertNil(inbox.receive(third))
        XCTAssertNil(inbox.presented, "the waiting alert is shown first, by presentNext")
        XCTAssertEqual(inbox.waiting, [failure, third])
        inbox.presentNext()
        XCTAssertEqual(inbox.presented, failure)
    }

    func testAcknowledgeOfADifferentAlertDoesNothing() {
        var inbox = FeedbackInbox()
        _ = inbox.receive(incomplete)
        inbox.acknowledge(failure)
        XCTAssertEqual(inbox.presented, incomplete)
        inbox.acknowledge(incomplete)
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
