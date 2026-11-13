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
        XCTAssertEqual(item.text, "Stopping after this photo… 3 of 10 done")
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

    // MARK: the five Library tools

    func testToolRowsKeepTheOldHUDTextsAndCannotBeCancelled() {
        let rows: [(ActivityItem, ActivityItem.Kind, String)] = [
            (.merging, .merge, "Merging photos…"),
            (.workingOnXMP, .xmp, "Working on XMP files…"),
            (.movingToTrash, .trash, "Moving photos to the Trash…"),
            (.workingOnBackup, .backup, "Working on the catalog backup…")
        ]
        for (item, kind, text) in rows {
            XCTAssertEqual(item.kind, kind)
            XCTAssertEqual(item.text, text)
            XCTAssertEqual(item.progress, .indeterminate)
            XCTAssertFalse(item.canCancel)
        }
    }

    func testCopyingCountsWhenTheTotalIsKnown() {
        let counting = ActivityItem.copying(done: 3, total: 12)
        XCTAssertEqual(counting.text, "Copying photos… 3 of 12")
        XCTAssertEqual(counting.progress, .steps(done: 3, total: 12))
        XCTAssertEqual(counting.kind, .importCopy)
        XCTAssertFalse(counting.canCancel)
        let unknown = ActivityItem.copying(done: 0, total: 0)
        XCTAssertEqual(unknown.text, "Copying photos…")
        XCTAssertEqual(unknown.progress, .indeterminate)
    }

    func testOrderedFollowsKindOrderAndKeepsOneRowPerKind() {
        let mixed: [ActivityItem] = [.copying(done: 1, total: 2), .merging, .enhancing, .export(completed: 0, total: 2, stopping: false), .movingToTrash]
        XCTAssertEqual(ActivityItem.ordered(mixed).map(\.kind), [.export, .enhance, .merge, .trash, .importCopy])
        let twice = ActivityItem.ordered([.copying(done: 1, total: 4), .copying(done: 2, total: 4)])
        XCTAssertEqual(twice, [.copying(done: 2, total: 4)])
        XCTAssertEqual(ActivityItem.Kind.allCases.map(\.rawValue), ["export", "enhance", "importFolders", "merge", "xmp", "trash", "backup", "importCopy"])
    }
}
