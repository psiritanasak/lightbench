import CoreImage
import XCTest
@testable import PhotoApp

@MainActor
final class SectionResetModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SectionReset-\(UUID().uuidString)")
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

    func testResetLightIsOneLabelledStepAndOneUndoRestoresIt() async throws {
        let model = try await makeModel()
        model.editState.exposureEV = 1
        model.editState.contrast = 0.3
        model.editState.vibrance = 0.4
        model.resetSection(.pointColor) // a no-op reset that flushes the pending burst into its own step
        let before = model.editState
        let steps = model.historyEntries.count
        model.resetSection(.light)
        XCTAssertEqual(model.editState.exposureEV, 0)
        XCTAssertEqual(model.editState.contrast, 0)
        XCTAssertEqual(model.editState.vibrance, 0.4, "other sections are untouched")
        XCTAssertEqual(model.historyEntries.count, steps + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Light")
        model.undo()
        XCTAssertEqual(model.editState, before)
    }

    func testAPendingBurstIsFlushedIntoItsOwnStepFirst() async throws {
        let model = try await makeModel()
        let steps = model.historyEntries.count
        model.editState.exposureEV = 1 // still inside the coalescing window
        model.resetSection(.light)
        XCTAssertEqual(model.historyEntries.count, steps + 2, "the edit and the reset are separate steps")
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Light")
        model.undo()
        XCTAssertEqual(model.editState.exposureEV, 1)
    }

    func testNoStepWhenTheSectionIsAlreadyClean() async throws {
        let model = try await makeModel()
        let steps = model.historyEntries.count
        model.resetSection(.light)
        model.resetAdjustments()
        XCTAssertEqual(model.historyEntries.count, steps)
    }

    func testResetAdjustmentsKeepsRedEyeAndRawFieldsAndClearsPointColors() async throws {
        let model = try await makeModel()
        model.editState.redEyeSize = 0.9
        model.editState.redEyeStrength = 0.2
        model.editState.rawExposureEV = 0.5
        model.editState.rawDecoderVersionPin = "pin-1"
        model.editState.pointColors = [PointColor()]
        model.editState.exposureEV = 1
        model.editState.grain = 0.5
        model.resetSection(.pointColor) // a no-op reset that flushes the pending burst into its own step
        let steps = model.historyEntries.count
        model.resetAdjustments()
        XCTAssertEqual(model.editState.redEyeSize, 0.9)
        XCTAssertEqual(model.editState.redEyeStrength, 0.2)
        XCTAssertEqual(model.editState.rawExposureEV, 0.5)
        XCTAssertEqual(model.editState.rawDecoderVersionPin, "pin-1")
        XCTAssertTrue(model.editState.pointColors.isEmpty)
        XCTAssertEqual(model.editState.exposureEV, 0)
        XCTAssertEqual(model.editState.grain, 0)
        XCTAssertEqual(model.historyEntries.count, steps + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Adjustments")
    }
}
