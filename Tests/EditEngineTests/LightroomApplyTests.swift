import XCTest
import CoreImage
@testable import PhotoApp

/// `ImageDocumentModel.applyLightroomSettings` end to end on a real loaded photo: one undo step, the preset-style preservation
/// of geometry / masks / spots / RAW fields, absent keys, and the opt-in crop.
@MainActor
final class LightroomApplyTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LightroomApplyTests-\(UUID().uuidString)")
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

    private func plan(_ scalars: [String: String], includeCrop: Bool = false) -> LightroomMapping.Plan {
        LightroomMapping.plan(from: AdobeCameraRawSettings(scalars: scalars), includeCrop: includeCrop)
    }

    func testImportIsOneUndoStepWithTheLightroomLabel() async throws {
        let model = try await makeModel()
        let before = model.editState
        let steps = model.historyEntries.count
        XCTAssertTrue(model.applyLightroomSettings(plan(["Exposure2012": "+0.65", "Highlights2012": "-28", "Vibrance": "+10"])))
        XCTAssertEqual(model.editState.exposureEV, 0.65, accuracy: 1e-12)
        XCTAssertEqual(model.editState.curvesHighlights, -0.28, accuracy: 1e-12)
        XCTAssertEqual(model.historyEntries.count, steps + 1, "ONE step for the whole import")
        XCTAssertEqual(model.historyEntries.last?.summary, "Lightroom Settings")
        model.undo()
        XCTAssertEqual(model.editState, before, "a single undo restores the photo exactly")
    }

    func testGeometryMasksSpotsAndRawFieldsAreKept() async throws {
        let model = try await makeModel()
        model.editState.straightenAngle = 4
        model.editState.flipVertical = true
        model.editState.masks = [Mask()]
        model.editState.redEyePoints = [RedEyePoint(x: 0.3, y: 0.3)]
        model.editState.retouchSpots = [RetouchSpot()]
        model.editState.rawExposureEV = 0.4
        model.editState.whiteBalanceTemperature = 5200
        model.editState.exposureEV = -2
        try await Task.sleep(nanoseconds: 600_000_000)
        let kept = model.editState
        XCTAssertFalse(kept.retouchSpots.isEmpty, "the spots test is only meaningful with spots present")
        XCTAssertTrue(model.applyLightroomSettings(plan(["Exposure2012": "+1"])))
        XCTAssertEqual(model.editState.exposureEV, 1)
        XCTAssertEqual(model.editState.straightenAngle, kept.straightenAngle)
        XCTAssertEqual(model.editState.flipVertical, kept.flipVertical)
        XCTAssertEqual(model.editState.masks, kept.masks)
        XCTAssertEqual(model.editState.redEyePoints, kept.redEyePoints)
        XCTAssertEqual(model.editState.retouchSpots, kept.retouchSpots)
        XCTAssertEqual(model.editState.rawExposureEV, 0.4)
        XCTAssertEqual(model.editState.whiteBalanceTemperature, 5200)
    }

    func testCropIsAppliedOnlyWhenIncluded() async throws {
        let crop = ["HasCrop": "True", "CropLeft": "0.1", "CropTop": "0.1", "CropRight": "0.9", "CropBottom": "0.8"]
        let off = try await makeModel()
        off.applyLightroomSettings(plan(crop.merging(["Exposure2012": "+1"]) { a, _ in a }, includeCrop: false))
        XCTAssertEqual(off.editState.cropInsetLeft, 0)
        XCTAssertEqual(off.editState.cropInsetBottom, 0)

        let on = try await makeModel()
        XCTAssertTrue(on.applyLightroomSettings(plan(crop, includeCrop: true)))
        XCTAssertEqual(on.editState.cropInsetLeft, 0.1, accuracy: 1e-12)
        XCTAssertEqual(on.editState.cropInsetRight, 0.1, accuracy: 1e-12)
        XCTAssertEqual(on.editState.cropInsetBottom, 0.2, accuracy: 1e-12)
    }

    func testAnAbsentKeyDoesNotWipeTheUsersValueThroughTheDocument() async throws {
        let model = try await makeModel()
        model.editState.contrast = 0.5
        model.editState.texture = 0.3
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(model.applyLightroomSettings(plan(["Vibrance": "+10"])))
        XCTAssertEqual(model.editState.contrast, 0.5)
        XCTAssertEqual(model.editState.texture, 0.3)
        XCTAssertEqual(model.editState.vibrance, 0.10, accuracy: 1e-12)
    }

    func testARefusedPlanChangesNothing() async throws {
        let model = try await makeModel()
        let steps = model.historyEntries.count
        let refused = plan(["ProcessVersion": "3.7", "Exposure": "+1"])
        XCTAssertNotNil(refused.refusal)
        XCTAssertFalse(model.applyLightroomSettings(refused))
        XCTAssertEqual(model.historyEntries.count, steps)
    }

    func testNothingToChangeAddsNoHistoryStep() async throws {
        let model = try await makeModel()
        let steps = model.historyEntries.count
        XCTAssertFalse(model.applyLightroomSettings(plan([:])))
        XCTAssertEqual(model.historyEntries.count, steps)
    }

    func testAPendingSliderBurstIsFinalizedBeforeTheImport() async throws {
        let model = try await makeModel()
        model.editState.contrast = 0.5
        XCTAssertTrue(model.applyLightroomSettings(plan(["Exposure2012": "+1"])))
        model.undo()
        XCTAssertEqual(model.editState.contrast, 0.5, "the in-flight burst became its own step; undoing the import keeps it")
    }
}
