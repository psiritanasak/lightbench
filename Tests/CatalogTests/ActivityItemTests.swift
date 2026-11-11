import XCTest
@testable import PhotoApp

final class ActivityItemTests: XCTestCase {
    func testExportTextIsTodaysHUDText() {
        let item = ActivityItem.export(completed: 3, total: 10, stopping: false)
        XCTAssertEqual(item.text, "Exporting 3 of 10…")
        XCTAssertEqual(item.progress, .steps(done: 3, total: 10))
        XCTAssertEqual(item.kind, .export)
    }

    func testStoppingTextAndNoCancel() {
        let item = ActivityItem.export(completed: 3, total: 10, stopping: true)
        XCTAssertEqual(item.text, "Stopping after this photo…")
        XCTAssertFalse(item.canCancel)
    }

    /// `completed` = photos finished, so the photo in flight has index `completed`: Cancel needs one more photo waiting after it.
    func testCanCancelOnlyWhenAPhotoIsStillWaitingAfterTheOneInFlight() {
        XCTAssertTrue(ActivityItem.export(completed: 0, total: 3, stopping: false).canCancel)
        XCTAssertTrue(ActivityItem.export(completed: 1, total: 3, stopping: false).canCancel)
        XCTAssertFalse(ActivityItem.export(completed: 2, total: 3, stopping: false).canCancel, "last photo in flight: nothing left to stop")
        XCTAssertFalse(ActivityItem.export(completed: 3, total: 3, stopping: false).canCancel)
        XCTAssertFalse(ActivityItem.export(completed: 0, total: 1, stopping: false).canCancel)
    }

    func testEnhancingIsIndeterminateAndCannotBeCancelled() {
        XCTAssertEqual(ActivityItem.enhancing.text, "Enhancing…")
        XCTAssertEqual(ActivityItem.enhancing.progress, .indeterminate)
        XCTAssertFalse(ActivityItem.enhancing.canCancel)
        XCTAssertEqual(ActivityItem.enhancing.kind, .enhance)
    }
}
