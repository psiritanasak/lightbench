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
            "CollectionSidebarView.swift": 2,
            "FeedbackAlertModifier.swift": 1,
            "LibraryGridView.swift": 1,
            "LooksTabView.swift": 1,
            "PeopleSheetView.swift": 1,
        ]
        var found: [String: Int] = [:]
        for (name, lines) in try codeLines() {
            let n = lines.filter { $0.contains(".alert(") }.count
            if n > 0 { found[name] = n }
        }
        XCTAssertEqual(found, allowed, "an alert site was added or removed: list it in `allowed` with a verdict")
    }

    /// ONE `feedbackAlert` in `ContentView` takes every converted model's result (the single slots and the two posted queues) into one
    /// inbox (stacked alert modifiers can leave an alert stuck when two fire together).
    func testContentViewHasOneFeedbackAlertNamingEverySourceAndQueue() throws {
        let lines = try XCTUnwrap(try codeLines()["ContentView.swift"])
        let calls = lines.filter { $0.contains(".feedbackAlert(") }
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertTrue(call.contains("feedbackSources"))
        XCTAssertTrue(call.contains("feedbackQueues"))
        // The bindings live in the two computed lists; the list grows as models are converted.
        let text = lines.joined(separator: "\n")
        for binding in [
            "$pasteModel.feedback", "$enhanceModel.feedback", "$exportModel.feedback",
            "$catalog.catalogFeedback", "$renameModel.feedback", "$catalog.postedFeedback", "$document.postedFeedback",
        ] {
            XCTAssertTrue(text.contains(binding), "ContentView names \(binding)")
        }
    }

    /// The sheets live in several UI files (ContentView hosts two; the rest are in the sheet views and dialog modifiers). Eight are listed in
    /// `ContentView.anySheetPresented`, the Copy Photos setup sheet through `catalog.importCopySheetPresented`.
    func testEverySheetIsKnownToTheToastPause() throws {
        let all = try codeLines()
        let found = all.mapValues { $0.filter { $0.contains(".sheet(") }.count }.filter { $0.value > 0 }
        XCTAssertEqual(found.values.reduce(0, +), 9, "list the new sheet in ContentView.anySheetPresented, then update this count")
        XCTAssertEqual(found["ImportCopyDialogModifier.swift"], 1)
        let lines = try XCTUnwrap(all["ContentView.swift"])
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("var anySheetPresented") })
        let body = lines[start...].prefix(8).joined(separator: "\n")
        XCTAssertTrue(body.contains("catalog.importCopySheetPresented"), "the Copy Photos sheet pauses the toast clock")
    }

    /// The anchor markers that place toasts over the photo and the grid; Cull has none (whole-window fallback).
    func testPlacementMarkersAreOnTheEditorCanvasAndTheLibraryGrid() throws {
        let all = try codeLines()
        for file in ["ContentView.swift", "LibraryGridView.swift"] {
            let lines = try XCTUnwrap(all[file])
            XCTAssertEqual(lines.filter { $0.contains(".feedbackArea()") }.count, 1, file)
        }
        for (file, lines) in all where file != "ContentView.swift" && file != "LibraryGridView.swift" {
            XCTAssertFalse(lines.contains { $0.contains(".feedbackArea()") }, "\(file) must not mark an area (Cull falls back to the window)")
        }
    }

    /// A drain of several toasts shows the most severe one, not just the last.
    func testFeedbackAlertModifierShowsTheMostSevereToastOfADrain() throws {
        let lines = try XCTUnwrap(try codeLines()["FeedbackAlertModifier.swift"])
        // What it picks is what it shows: one statement, `toasts.show(` of the picked toast.
        XCTAssertTrue(lines.contains { $0.contains("FeedbackInbox.mostSevereToast(") && $0.contains("toasts.show(") })
    }

    /// The drop's "left out" note is an alert posted through the queue, never the single catalog slot (which a following result would
    /// replace).
    func testDropLeftOutNoteIsPostedNotWrittenToTheCatalogSlot() throws {
        let lines = try XCTUnwrap(try codeLines()["DropAndOpenModifier.swift"])
        let note = try XCTUnwrap(lines.firstIndex { $0.contains("catalog.post(") })
        XCTAssertTrue(lines[note...].prefix(3).joined().contains("message"))
        XCTAssertTrue(lines[note].contains("kind: .incomplete"), "the left-out note is an alert kind")
        XCTAssertFalse(lines.contains { $0.contains("catalogFeedback") }, "nothing in the drop modifier writes the single slot")
        let writers = lines.filter { $0.contains("importStatusMessage") }
        XCTAssertFalse(writers.contains { $0.contains("left out") || $0.contains("leftOut") })
    }

    /// Editor results reach the inbox through the document's queue: the tools' alerts are gone and the Lightroom modifier relays.
    func testEditorToolAlertsAreGoneAndNothingElseInTheEditorPostsRaw() throws {
        let all = try codeLines()
        for file in ["CropTabView.swift", "AdjustTabView.swift", "LightroomImportModel.swift", "ContentView.swift"] {
            XCTAssertFalse(try XCTUnwrap(all[file]).contains { $0.contains(".alert(") }, file)
        }
        let text = try XCTUnwrap(all["ImageDocumentModel.swift"]).joined(separator: "\n")
        for name in ["straightenMessage", "uprightMessage", "autoCropMessage", "retouchMessage", "subjectMaskMessage", "depthMaskMessage"] {
            XCTAssertTrue(text.contains("var \(name): String? { didSet { postEditorMessage(\(name),"), name)
        }
        for name in ["loadErrorMessage", "whiteBalanceSampleMessage", "sidecarSaveErrorMessage"] {
            XCTAssertTrue(text.contains("var \(name): String? { didSet { postEditorMessage(\(name),"), name)
        }
    }
}
