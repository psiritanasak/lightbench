import CoreImage
import XCTest
@testable import PhotoApp

/// `ImageDocumentModel.selectStyle` / `resetStyle`: each is its own labelled, undoable History step.
@MainActor
final class StyleModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("StyleModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() async throws -> ImageDocumentModel {
        let url = dir.appendingPathComponent("photo.png")
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: url)
        return model
    }

    func testSelectingAPresetIsOneLabelledUndoableStep() async throws {
        let model = try await makeModel()
        let before = model.historyEntries.count
        model.selectStyle("builtin:cinema")
        XCTAssertEqual(model.editState.styleID, "builtin:cinema")
        XCTAssertEqual(model.historyEntries.count, before + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Style: Cinema")
        model.undo()
        XCTAssertEqual(model.editState.styleID, "")
    }

    func testPickingTheSamePresetAgainIsANoOpWithoutAHistoryStep() async throws {
        let model = try await makeModel()
        model.selectStyle("builtin:vivid")
        let count = model.historyEntries.count
        model.selectStyle("builtin:vivid")
        XCTAssertEqual(model.historyEntries.count, count)
    }

    func testChoosingNoneKeepsStrengthWhileThePadIsOffCentreBecauseItStillScalesThePad() async throws {
        let model = try await makeModel()
        model.selectStyle("builtin:haze")
        model.editState.styleStrength = 0.4
        model.editState.styleTone = 0.3
        model.selectStyle("")
        XCTAssertEqual(model.editState.styleID, "")
        XCTAssertEqual(model.editState.styleStrength, 0.4, "the pad's rendered effect must not jump when only the preset is dropped")
        XCTAssertEqual(model.editState.styleTone, 0.3)
        XCTAssertEqual(model.historyEntries.last?.summary, "Style: None")
    }

    func testChoosingNoneWithACentredPadRestoresStrengthSoNoInvisibleEditRemains() async throws {
        let model = try await makeModel()
        model.selectStyle("builtin:haze")
        model.editState.styleStrength = 0.4
        model.selectStyle("")
        XCTAssertEqual(model.editState.styleStrength, 1)
        XCTAssertTrue(model.editState.isEffectivelyIdentity)
    }

    func testSelectingAStyleMidBurstCommitsTheBurstAsItsOwnStepFirst() async throws {
        let model = try await makeModel()
        let base = model.historyEntries.count
        model.editState.styleTone = 0.6          // a drag still inside its ~350ms coalescing window
        model.editState.styleStrength = 0.5
        model.selectStyle("builtin:haze")
        XCTAssertEqual(model.historyEntries.count, base + 2, "the burst, then the style")
        model.undo()
        XCTAssertEqual(model.editState.styleID, "")
        XCTAssertEqual(model.editState.styleTone, 0.6, "the burst step survives")
        XCTAssertEqual(model.editState.styleStrength, 0.5)
        model.undo()
        XCTAssertEqual(model.editState.styleTone, 0)
    }

    func testResetStyleClearsEverythingInOneStepAndIsANoOpWhenAlreadyClear() async throws {
        let model = try await makeModel()
        let clean = model.historyEntries.count
        model.resetStyle()
        XCTAssertEqual(model.historyEntries.count, clean, "nothing to reset, no history step")
        model.selectStyle("builtin:copper")
        model.editState.styleTone = -0.5; model.editState.styleColor = 0.5; model.editState.styleStrength = 0.2
        model.resetStyle()
        XCTAssertEqual(model.editState.styleID, "")
        XCTAssertEqual(model.editState.styleTone, 0); XCTAssertEqual(model.editState.styleColor, 0)
        XCTAssertEqual(model.editState.styleStrength, 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Style")
        model.undo()
        XCTAssertEqual(model.editState.styleID, "builtin:copper", "Undo restores the style")
    }

    func testAnUnknownStyleIdKeepsItsNameInTheHistoryLabel() async throws {
        let model = try await makeModel()
        model.selectStyle("builtin:from-a-newer-build")
        XCTAssertEqual(model.historyEntries.last?.summary, "Style: builtin:from-a-newer-build")
    }

    /// The colour-range eyedropper samples BEFORE the detail stages by zeroing the user's Texture/Clarity/Sharpen/Grain; the
    /// Style's texture and Grain are detail stages too and must not leak a halo/blur/noise into the sample.
    func testTheColorRangeEyedropperIgnoresTheStylesTextureAndGrain() async throws {
        let url = dir.appendingPathComponent("edge.png")
        let left = CIImage(color: CIColor(red: 0.5, green: 0.12, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 128))
        let right = CIImage(color: CIColor(red: 0.95, green: 0.4, blue: 0.3)).cropped(to: CGRect(x: 64, y: 0, width: 64, height: 128))
        try CIContext().writePNGRepresentation(of: right.composited(over: left), to: url, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: url)
        var mask = Mask(); mask.kind = .colorRange
        model.editState.masks = [mask]
        try await Task.sleep(nanoseconds: 500_000_000)

        func sampledLuminance(_ configure: (inout EditState) -> Void) throws -> Double {
            var state = model.editState
            state.masks[0].colorRangeHasTarget = false
            configure(&state)
            model.editState = state
            model.pickColorRangeTarget(maskID: mask.id, normalizedX: 0.5, normalizedY: 0.5)
            return try XCTUnwrap(model.editState.masks.first?.colorRangeTargetLuminance)
        }
        let plain = try sampledLuminance { _ in }
        let styled = try sampledLuminance { $0.styleTexture = "film"; $0.styleTextureAmount = 1; $0.styleGrain = true }
        XCTAssertEqual(styled, plain, accuracy: 1e-9, "style texture/grain must not reach the eyedropper sample")
    }

    // MARK: Texture and Grain

    func testSelectingATextureIsOneLabelledUndoableStep() async throws {
        let model = try await makeModel()
        let before = model.historyEntries.count
        model.selectStyleTexture("soft")
        XCTAssertEqual(model.editState.styleTexture, "soft")
        XCTAssertEqual(model.historyEntries.count, before + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Style Texture: Soft")
        model.selectStyleTexture("soft")
        XCTAssertEqual(model.historyEntries.count, before + 1, "the same texture again adds no history step (the guard and EditHistory both ensure this)")
        model.undo()
        XCTAssertEqual(model.editState.styleTexture, "")
    }

    func testChoosingNoTextureAlwaysRestoresItsStrengthButNeverTouchesGrainOrTheStyle() async throws {
        let model = try await makeModel()
        model.selectStyle("builtin:haze")
        model.setStyleGrain(true)
        model.selectStyleTexture("film")
        model.editState.styleTextureAmount = 0.3
        model.editState.styleStrength = 0.5
        model.selectStyleTexture("")
        XCTAssertEqual(model.editState.styleTexture, "")
        XCTAssertEqual(model.editState.styleTextureAmount, 1, "a texture-less amount is an invisible edit, even with Grain on")
        XCTAssertTrue(model.editState.styleGrain, "Grain is independent of the texture")
        XCTAssertEqual(model.editState.styleStrength, 0.5, "the preset's own strength is not the texture's")
        XCTAssertEqual(model.editState.styleID, "builtin:haze")
        XCTAssertEqual(model.historyEntries.last?.summary, "Style Texture: None")
    }

    func testTheGrainToggleIsLabelledUndoableAndIdempotent() async throws {
        let model = try await makeModel()
        let before = model.historyEntries.count
        model.setStyleGrain(true)
        XCTAssertTrue(model.editState.styleGrain)
        XCTAssertEqual(model.historyEntries.last?.summary, "Style Grain: On")
        model.setStyleGrain(true)
        XCTAssertEqual(model.historyEntries.count, before + 1)
        model.setStyleGrain(false)
        XCTAssertEqual(model.historyEntries.last?.summary, "Style Grain: Off")
        model.undo()
        XCTAssertTrue(model.editState.styleGrain)
    }

    func testResetStyleAlsoClearsTextureAmountAndGrainInOneStep() async throws {
        let model = try await makeModel()
        model.selectStyleTexture("glow")
        model.editState.styleTextureAmount = 0.4
        model.setStyleGrain(true)
        model.resetStyle()
        XCTAssertEqual(model.editState.styleTexture, "")
        XCTAssertEqual(model.editState.styleTextureAmount, 1)
        XCTAssertFalse(model.editState.styleGrain)
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Style")
        model.undo()
        XCTAssertEqual(model.editState.styleTexture, "glow")
        XCTAssertTrue(model.editState.styleGrain)
    }

    func testSelectingATextureMidBurstCommitsTheBurstFirst() async throws {
        let model = try await makeModel()
        let base = model.historyEntries.count
        model.editState.styleTextureAmount = 0.6          // a slider drag still inside its coalescing window
        model.selectStyleTexture("film")
        XCTAssertEqual(model.historyEntries.count, base + 2, "the burst, then the texture")
        model.undo()
        XCTAssertEqual(model.editState.styleTexture, "")
        XCTAssertEqual(model.editState.styleTextureAmount, 0.6)
    }
}
