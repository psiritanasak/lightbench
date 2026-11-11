import XCTest
@testable import PhotoApp

final class ToastTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }
    private let toast = Feedback(kind: .done, title: "Export", message: "Exported 2 photos.")
    private let other = Feedback(kind: .warning, title: "Enhance", message: "Used Lanczos.")

    func testShowGivesAFourSecondWakeAndTenWithVoiceOver() throws {
        var timeline = ToastTimeline()
        let wake = try XCTUnwrap(timeline.show(toast, now: t0, voiceOver: false))
        XCTAssertEqual(wake.after, 4)
        XCTAssertEqual(timeline.current?.feedback, toast)
        var voiceOver = ToastTimeline()
        XCTAssertEqual(voiceOver.show(toast, now: t0, voiceOver: true)?.after, 10)
    }

    func testAnAlertKindIsRefused() {
        var timeline = ToastTimeline()
        XCTAssertNil(timeline.show(Feedback.error("Export", "No."), now: t0, voiceOver: false))
        XCTAssertNil(timeline.current)
        _ = timeline.show(toast, now: t0, voiceOver: false)
        XCTAssertNil(timeline.show(Feedback(kind: .incomplete, title: "x", message: "y"), now: at(1), voiceOver: false))
        XCTAssertEqual(timeline.current?.feedback, toast, "a refused alert leaves the toast alone")
    }

    func testReplacementGetsANewIDAndTheOldWakeIsIgnored() throws {
        var timeline = ToastTimeline()
        let first = try XCTUnwrap(timeline.show(toast, now: t0, voiceOver: false))
        let second = try XCTUnwrap(timeline.show(other, now: at(1), voiceOver: false))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(timeline.wake(first, now: at(4)), .ignored)
        XCTAssertEqual(timeline.current?.feedback, other)
    }

    func testEarlyWakeAsksAgainAndDueWakeExpires() throws {
        var timeline = ToastTimeline()
        let wake = try XCTUnwrap(timeline.show(toast, now: t0, voiceOver: false))
        guard case .again(let next) = timeline.wake(wake, now: at(1)) else { return XCTFail("expected .again") }
        XCTAssertEqual(next.after, 3, accuracy: 0.0001)
        XCTAssertEqual(timeline.wake(next, now: at(4)), .expired)
        XCTAssertNil(timeline.current)
    }

    func testHoverMakesTheOldWakeStaleAndResumeUsesWhatIsLeft() throws {
        var timeline = ToastTimeline()
        let wake = try XCTUnwrap(timeline.show(toast, now: t0, voiceOver: false))
        XCTAssertNil(timeline.setPaused(.hover, true, now: at(1)))
        XCTAssertEqual(timeline.wake(wake, now: at(4)), .ignored)
        XCTAssertNotNil(timeline.current)
        let resumed = try XCTUnwrap(timeline.setPaused(.hover, false, now: at(10)))
        XCTAssertEqual(resumed.after, 3, accuracy: 0.0001)
        XCTAssertEqual(timeline.wake(resumed, now: at(13)), .expired)
    }

    func testResumeWithLittleLeftWaitsTheMinimum() throws {
        var timeline = ToastTimeline()
        _ = timeline.show(toast, now: t0, voiceOver: false)
        _ = timeline.setPaused(.hover, true, now: at(3.5))
        let resumed = try XCTUnwrap(timeline.setPaused(.hover, false, now: at(9)))
        XCTAssertEqual(resumed.after, 1.5, accuracy: 0.0001)
    }

    func testSheetAndHoverBothHoldTheClock() throws {
        var timeline = ToastTimeline()
        _ = timeline.show(toast, now: t0, voiceOver: false)
        XCTAssertNil(timeline.setPaused(.sheet, true, now: at(1)))
        XCTAssertNil(timeline.setPaused(.hover, true, now: at(2)))
        XCTAssertNil(timeline.setPaused(.hover, false, now: at(3)), "the sheet still holds it")
        let resumed = try XCTUnwrap(timeline.setPaused(.sheet, false, now: at(40)))
        XCTAssertEqual(resumed.after, 3, accuracy: 0.0001, "only the first second ran: the clock stopped at 1 and no pause in between moved it")
        XCTAssertEqual(timeline.wake(resumed, now: at(43)), .expired)
    }

    func testSeveralPausesAddUpAndAnOlderWakeOfTheSameToastIsIgnored() throws {
        var timeline = ToastTimeline()
        let first = try XCTUnwrap(timeline.show(toast, now: t0, voiceOver: false))
        _ = timeline.setPaused(.hover, true, now: at(1))                                    // ran 1 s
        let second = try XCTUnwrap(timeline.setPaused(.hover, false, now: at(10)))
        XCTAssertEqual(second.after, 3, accuracy: 0.0001)
        _ = timeline.setPaused(.hover, true, now: at(11))                                   // ran 2 s in all
        let third = try XCTUnwrap(timeline.setPaused(.hover, false, now: at(20)))
        XCTAssertEqual(third.after, 2, accuracy: 0.0001)
        XCTAssertEqual(first.id, third.id)
        XCTAssertEqual(timeline.wake(first, now: at(21)), .ignored, "same toast, older generation")
        XCTAssertEqual(timeline.wake(second, now: at(21)), .ignored)
        XCTAssertNotNil(timeline.current)
        XCTAssertEqual(timeline.wake(third, now: at(22)), .expired)
    }

    func testShowWhilePausedGivesNoWakeAndTheFullDuration() throws {
        var timeline = ToastTimeline()
        XCTAssertNil(timeline.setPaused(.sheet, true, now: t0))
        XCTAssertNil(timeline.show(toast, now: at(1), voiceOver: false))
        XCTAssertEqual(try XCTUnwrap(timeline.remaining(now: at(50))), 4, accuracy: 0.0001)
        let resumed = try XCTUnwrap(timeline.setPaused(.sheet, false, now: at(60)))
        XCTAssertEqual(resumed.after, 4, accuracy: 0.0001)
    }

    func testReplacementClearsHoverAndKeepsSheet() throws {
        var timeline = ToastTimeline()
        _ = timeline.show(toast, now: t0, voiceOver: false)
        _ = timeline.setPaused(.hover, true, now: at(1))
        _ = timeline.setPaused(.sheet, true, now: at(1))
        XCTAssertNil(timeline.show(other, now: at(2), voiceOver: false), "the sheet still pauses")
        XCTAssertEqual(timeline.pauseReasons, [.sheet])
    }

    func testStaleDismissDoesNothingAndDismissClearsHover() throws {
        var timeline = ToastTimeline()
        let first = try XCTUnwrap(timeline.show(toast, now: t0, voiceOver: false))
        _ = timeline.show(other, now: at(1), voiceOver: false)
        timeline.dismiss(id: first.id)
        XCTAssertEqual(timeline.current?.feedback, other)
        _ = timeline.setPaused(.hover, true, now: at(2))
        timeline.dismiss(id: try XCTUnwrap(timeline.current).id)
        XCTAssertNil(timeline.current)
        XCTAssertTrue(timeline.pauseReasons.isEmpty)
    }
}
