import XCTest
@testable import PhotoApp

@MainActor
final class ActivityCenterTests: XCTestCase {
    func testSetKeepsKindOrderAndNilClears() {
        let center = ActivityCenter()
        center.set(.importCopy, .copying(done: 1, total: 3))
        center.set(.merge, .merging)
        center.set(.trash, .movingToTrash)
        XCTAssertEqual(center.items.map(\.kind), [.merge, .trash, .importCopy])
        center.set(.merge, nil)
        XCTAssertEqual(center.items.map(\.kind), [.trash, .importCopy])
        center.set(.importCopy, .copying(done: 2, total: 3))
        XCTAssertEqual(center.items.last?.text, "Copying photos… 2 of 3", "one row per kind, updated in place")
        center.set(.trash, nil)
        center.set(.importCopy, nil)
        XCTAssertTrue(center.items.isEmpty)
    }

    func testCatalogOwnsTheCenterAndIdleToolsHaveNoRow() throws {
        let catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: UserDefaults(suiteName: "ActivityCenterTests-\(UUID().uuidString)")!)
        XCTAssertTrue(catalog.activity.items.isEmpty)
        XCTAssertNil(catalog.merge.activityItem)
        XCTAssertNil(catalog.xmp.activityItem)
        XCTAssertNil(catalog.trash.activityItem)
        XCTAssertNil(catalog.catalogBackup.activityItem)
        XCTAssertNil(catalog.importCopy.activityItem)
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testTheFiveWorkingHUDsAreGoneAndEachModifierReportsItsRow() throws {
        let files: [(String, String, String)] = [
            ("Merge", "MergingHUD", ".merge"), ("XMP", "XMPWorkingHUD", ".xmp"), ("Trash", "TrashWorkingHUD", ".trash"),
            ("CatalogBackup", "CatalogBackupWorkingHUD", ".backup"), ("ImportCopy", "ImportCopyWorkingHUD", ".importCopy")
        ]
        for (name, hud, kind) in files {
            let text = try source("Sources/UI/\(name)DialogModifier.swift")
            XCTAssertFalse(text.contains("struct \(hud)"), hud)
            XCTAssertFalse(text.contains(".overlay(alignment: .bottom)"), "\(name): no HUD overlay")
            XCTAssertTrue(text.contains("catalog.activity.set(\(kind), item)"), name)
            XCTAssertTrue(text.contains("catalog.activity.set(\(kind), nil)"), "\(name): cleared when the modifier leaves")
        }
    }

    func testOnlyTheFeedbackHostObservesTheCenter() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("@ObservedObject var tools: ActivityCenter"))
        XCTAssertFalse(content.contains("catalog.merge.isMerging") || content.contains("catalog.activity.items"))
    }
}
