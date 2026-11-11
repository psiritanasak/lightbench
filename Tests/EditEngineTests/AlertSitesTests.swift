import XCTest
@testable import PhotoApp

/// Every `.alert(` in the app is listed with a verdict, so a new one is a conscious choice (a passing result belongs in a toast through
/// `feedbackAlert`), and every sheet in `ContentView` is known to the toast pause.
final class AlertSitesTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Code lines of each Swift file under `Sources/` (drops `//` comments, as `CullWiringTests.source()` does).
    private func codeLines() throws -> [String: [String]] {
        let sources = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "found the sources")
        var result: [String: [String]] = [:]
        for file in files {
            result[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .map { $0.components(separatedBy: "//").first ?? "" }
        }
        return result
    }

    func testEveryAlertSiteIsListed() throws {
        // Verdicts: every entry is still a raw alert to be converted to `feedbackAlert` or kept because it asks a question / needs a decision;
        // FeedbackAlertModifier is the one generic alert.
        let allowed: [String: Int] = [
            "AdjustTabView.swift": 3,
            "CatalogBackupDialogModifier.swift": 1,
            "CollectionSidebarView.swift": 6,
            "ContentView.swift": 5,
            "CropTabView.swift": 3,
            "FeedbackAlertModifier.swift": 1,
            "ImportCopyDialogModifier.swift": 1,
            "LibraryGridView.swift": 1,
            "LightroomImportModel.swift": 1,
            "LooksTabView.swift": 2,
            "MergeDialogModifier.swift": 1,
            "PeopleSheetView.swift": 1,
            "TrashDialogModifier.swift": 1,
            "XMPDialogModifier.swift": 1,
        ]
        var found: [String: Int] = [:]
        for (name, lines) in try codeLines() {
            let n = lines.filter { $0.contains(".alert(") }.count
            if n > 0 { found[name] = n }
        }
        XCTAssertEqual(found, allowed, "an alert site was added or removed: list it in `allowed` with a verdict")
    }

    /// ONE `feedbackAlert` in `ContentView` takes all three models' results into one inbox (three stacked alert modifiers can leave an
    /// alert stuck when two fire together).
    func testContentViewHasOneFeedbackAlertNamingAllThreeModels() throws {
        let lines = try XCTUnwrap(try codeLines()["ContentView.swift"])
        let calls = lines.filter { $0.contains(".feedbackAlert(") }
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        for binding in ["$pasteModel.feedback", "$enhanceModel.feedback", "$exportModel.feedback"] {
            XCTAssertTrue(call.contains(binding), "feedbackAlert names \(binding)")
        }
    }

    /// The sheets live in several UI files (ContentView hosts two; the rest are in the sheet views and dialog modifiers). Eight are listed in
    /// `ContentView.anySheetPresented`; the Copy Photos setup sheet (`ImportCopyDialogModifier`) is the known gap.
    func testEverySheetIsKnownToTheToastPause() throws {
        let all = try codeLines()
        let found = all.mapValues { $0.filter { $0.contains(".sheet(") }.count }.filter { $0.value > 0 }
        XCTAssertEqual(found.values.reduce(0, +), 9, "list the new sheet in ContentView.anySheetPresented, then update this count")
        XCTAssertEqual(found["ImportCopyDialogModifier.swift"], 1, "the one sheet NOT in anySheetPresented (known gap)")
    }
}
