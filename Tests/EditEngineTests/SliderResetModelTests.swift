import CoreImage
import SwiftUI
import XCTest
@testable import PhotoApp

@MainActor
final class SliderResetModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private nonisolated(unsafe) var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SliderReset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() async throws -> ImageDocumentModel {
        let url = dir.appendingPathComponent("photo.png")
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: url)
        return model
    }

    func testResetIsOneLabelledStepAndUndoRestoresTheValue() async throws {
        let model = try await makeModel()
        model.editState.exposureEV = 1
        model.performLabelledEdit("flush") { } // settles the burst into its own step
        let steps = model.historyEntries.count
        model.performLabelledEdit("Reset Exposure") { model.editState.exposureEV = 0 }
        XCTAssertEqual(model.editState.exposureEV, 0)
        XCTAssertEqual(model.historyEntries.count, steps + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Exposure")
        model.undo()
        XCTAssertEqual(model.editState.exposureEV, 1)
    }

    func testAPendingBurstIsItsOwnStepThenTheReset() async throws {
        let model = try await makeModel()
        let steps = model.historyEntries.count
        model.editState.exposureEV = 1 // still inside the coalescing window
        model.performLabelledEdit("Reset Exposure") { model.editState.exposureEV = 0 }
        XCTAssertEqual(model.historyEntries.count, steps + 2, "the burst, then the reset")
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Exposure")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.historyEntries.count, steps + 2, "the cancelled debounce never adds a third step")
        model.undo()
        XCTAssertEqual(model.editState.exposureEV, 1)
    }

    func testAWriteThatChangesNothingAddsNoStep() async throws {
        let model = try await makeModel()
        let steps = model.historyEntries.count
        model.performLabelledEdit("Reset Exposure") { model.editState.exposureEV = 0 }
        XCTAssertEqual(model.historyEntries.count, steps)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.historyEntries.count, steps)
    }

    func testAResetThroughAMaskBindingIsLabelledAndUndoable() async throws {
        let model = try await makeModel()
        var mask = Mask()
        mask.exposureEV = 2
        model.editState.masks = [mask]
        model.performLabelledEdit("flush") { }
        let steps = model.historyEntries.count
        let editState = Binding<EditState>(get: { model.editState }, set: { model.editState = $0 })
        let maskBinding = try XCTUnwrap(editState.mask(id: mask.id))
        model.performLabelledEdit("Reset Exposure") { maskBinding.wrappedValue.exposureEV = 0 }
        XCTAssertEqual(model.editState.masks.first?.exposureEV, 0)
        XCTAssertEqual(model.historyEntries.count, steps + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Exposure")
        model.undo()
        XCTAssertEqual(model.editState.masks.first?.exposureEV, 2)
    }

    func testTheEnvironmentDefaultJustRunsTheWrite() {
        var ran = false
        SliderResetAction.plain.perform("Reset X") { ran = true }
        XCTAssertTrue(ran)
    }

    // MARK: Source pins

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEditScrollInjectsTheResetAction() throws {
        let content = try source("Sources/UI/ContentView.swift")
        let start = try XCTUnwrap(content.range(of: "private var editScroll: some View {"))
        XCTAssertTrue(String(content[start.upperBound...].prefix(3500)).contains(".editSliderResets(document)"))
    }

    func testTheSliderIsNeverSwitchedBetweenModifiedAndUnmodifiedContent() throws {
        let rows = try source("Sources/UI/EditControlRows.swift")
        XCTAssertFalse(rows.contains("SliderResetAffordance"))
        XCTAssertTrue(rows.contains(".accessibilityActions {"))
    }

    func testNoCountTwoRecogniserInTheSliderFiles() throws {
        for file in ["Sources/UI/EditControlRows.swift", "Sources/UI/ThinSlider.swift"] {
            XCTAssertFalse(try source(file).contains("count: 2"), file)
        }
    }
}
