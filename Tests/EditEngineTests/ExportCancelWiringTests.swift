import XCTest
@testable import PhotoApp

/// `ExportModel`'s loop runs inside a detached task behind an `NSOpenPanel`, so it cannot be driven here without restructuring the model;
/// these pin the safety rules in the source instead: a stop is a flag read between photos, never Task cancellation, and the old HUDs are gone.
final class ExportCancelWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8).components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
    }

    func testExportModelReadsTheFlagInsideThePhotoLoopAndNeverCancelsATask() throws {
        let text = try source("Sources/UI/ExportModel.swift")
        let loop = try XCTUnwrap(text.range(of: "for (index, photo) in batch.enumerated() {"))
        let after = String(text[loop.upperBound...])
        let flag = try XCTUnwrap(after.range(of: "isCancelRequested"))
        let firstWork = try XCTUnwrap(after.range(of: "do {"))
        XCTAssertTrue(flag.lowerBound < firstWork.lowerBound, "the flag is read at the TOP of the iteration, before any photo work")
        XCTAssertFalse(text.contains(".cancel()"), "a stop is a flag, never Task cancellation")
        XCTAssertEqual(text.components(separatedBy: "enumerated() {").count - 1, 1, "one loop serves rendered and original export")
    }

    func testTheOldProgressHUDsAreGone() throws {
        let text = try source("Sources/UI/EditorChromeViews.swift")
        XCTAssertFalse(text.contains("struct ExportProgressHUD"))
        XCTAssertFalse(text.contains("struct EnhancingHUD"))
    }

    func testTheStripsCancelIsFocusableFalseAndWiredToTheExportModel() throws {
        let view = try source("Sources/UI/ToastView.swift")
        XCTAssertTrue(view.contains("Button(\"Cancel\")"))
        XCTAssertTrue(view.contains(".focusable(false)"))
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("exportModel.cancelExport()"))
    }
}
