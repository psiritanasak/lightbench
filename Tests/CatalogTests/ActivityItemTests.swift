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
        XCTAssertEqual(item.text, "Stopping after this photo… 3 of 10 exported")
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

    func testImportingFoldersIsIndeterminateAndCannotBeCancelled() {
        XCTAssertEqual(ActivityItem.importingFolders.text, "Importing photos…")
        XCTAssertEqual(ActivityItem.importingFolders.progress, .indeterminate)
        XCTAssertFalse(ActivityItem.importingFolders.canCancel)
        XCTAssertEqual(ActivityItem.importingFolders.kind, .importFolders)
    }

    func testStripListsExportThenEnhanceThenImport() {
        XCTAssertEqual(ActivityItem.strip(export: nil, stopping: false, enhancing: false, importingFolders: false), [])
        let all = ActivityItem.strip(export: (completed: 1, total: 5), stopping: false, enhancing: true, importingFolders: true)
        XCTAssertEqual(all.map(\.kind), [.export, .enhance, .importFolders])
        XCTAssertEqual(all.first, ActivityItem.export(completed: 1, total: 5, stopping: false))
        XCTAssertEqual(ActivityItem.strip(export: nil, stopping: true, enhancing: false, importingFolders: true).map(\.kind), [.importFolders])
    }

    func testEnhancingIsIndeterminateAndCannotBeCancelled() {
        XCTAssertEqual(ActivityItem.enhancing.text, "Enhancing…")
        XCTAssertEqual(ActivityItem.enhancing.progress, .indeterminate)
        XCTAssertFalse(ActivityItem.enhancing.canCancel)
        XCTAssertEqual(ActivityItem.enhancing.kind, .enhance)
    }
}
