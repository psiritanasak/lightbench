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
        XCTAssertFalse(content.contains("catalog.importCopy.progressDone"), "ContentView must not read the per-photo progress")
        // Exactly one observer of an ActivityCenter in all of Sources/UI, and it is FeedbackHostModifier's.
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var observers: [(file: String, line: String)] = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let code = line.components(separatedBy: "//").first ?? ""
                let wrapped = ["@ObservedObject", "@StateObject", "@EnvironmentObject"].contains { code.contains($0) }
                if wrapped, code.contains(": ActivityCenter") { observers.append((file.lastPathComponent, code)) }
            }
        }
        XCTAssertEqual(observers.count, 1, "\(observers)")
        XCTAssertEqual(observers.first?.file, "ContentView.swift")
        let text = content
        let host = try XCTUnwrap(text.range(of: "struct FeedbackHostModifier"))
        let observer = try XCTUnwrap(text.range(of: "@ObservedObject var tools: ActivityCenter"))
        XCTAssertGreaterThan(observer.lowerBound, host.lowerBound, "the one observer is inside FeedbackHostModifier")
    }

    func testEachModifierReportsItsRowOnAppearAndOnEveryChange() throws {
        for name in ["Merge", "XMP", "Trash", "CatalogBackup", "ImportCopy"] {
            let text = try source("Sources/UI/\(name)DialogModifier.swift")
            XCTAssertEqual(text.components(separatedBy: ".onChange(of: model.activityItem").count - 1, 1, name)
            XCTAssertTrue(text.contains(".onChange(of: model.activityItem, initial: true)"), "\(name): reports at once, not only on change")
        }
    }

    /// `isWorking` and the progress counters are `private(set)` (a run is needed to move them), so the copying row's shape is pinned in the
    /// source: while working it is built from the model's own counters.
    func testTheCopyingRowIsBuiltFromTheModelsOwnProgress() throws {
        let text = try source("Sources/UI/ImportCopyModel.swift")
        XCTAssertTrue(text.contains("var activityItem: ActivityItem? { isWorking ? .copying(done: progressDone, total: progressTotal) : nil }"))
    }
}
