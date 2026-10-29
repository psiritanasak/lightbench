import CoreImage
import XCTest
@testable import PhotoApp

/// `ImageDocumentModel.rotate(_:)` and the detectors / samplers that must see the ROTATED picture, on small temp PNGs.
@MainActor
final class RotateModelTests: XCTestCase {
    private final class Access: SidecarFolderAccessing {
        let folder: URL?
        init(folder: URL?) { self.folder = folder }
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
            guard let granted = self.folder else { return .declined }
            return .granted(granted)
        }
    }

    private final class GatedHorizon: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var _extents: [CGRect] = []
        var result: HorizonDetector.Result = .none
        var extents: [CGRect] { lock.lock(); defer { lock.unlock() }; return _extents }
        func detect(_ image: CIImage) -> HorizonDetector.Result {
            lock.lock(); _extents.append(image.extent); let r = result; lock.unlock()
            gate.wait()
            return r
        }
        func release() { gate.signal() }
    }

    private final class GatedUpright: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var _extents: [CGRect] = []
        var extents: [CGRect] { lock.lock(); defer { lock.unlock() }; return _extents }
        func detect(_ image: CIImage) -> UprightDetector.Result {
            lock.lock(); _extents.append(image.extent); lock.unlock()
            gate.wait()
            return .failed("test")
        }
        func release() { gate.signal() }
        /// Waits for the gate, then reports level horizontal lines whose solve would change Straighten (so a dropped result is visible).
        func detectLevelLines() -> UprightDetector.Result {
            gate.wait()
            return .lines(UprightModelTests.levelLines(ccwTilt: 4))
        }
    }

    private var dir: URL!
    private var scopedFolder: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RotateModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        scopedFolder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writePNG(_ image: CIImage, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return url
    }

    private func makeModel(width: Int = 48, height: Int = 32, saving: Bool = false) async throws -> ImageDocumentModel {
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let model = ImageDocumentModel(folderAccess: Access(folder: saving ? scopedFolder : nil))
        await model.load(from: try writePNG(base, name: "a.png"))
        return model
    }

    // MARK: - rotate(_:)

    func testRotateIsOneLabelledUndoStepAndRedoRestoresIt() async throws {
        let model = try await makeModel()
        let steps = model.historyEntries.count
        model.rotate(.right)
        XCTAssertEqual(model.editState.rotationQuarterTurns, 1)
        XCTAssertEqual(model.historyEntries.count, steps + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Rotate Right")
        model.rotate(.left)
        XCTAssertEqual(model.editState.rotationQuarterTurns, 0)
        XCTAssertEqual(model.historyEntries.last?.summary, "Rotate Left")
        XCTAssertEqual(model.historyEntries.count, steps + 2)
        model.undo()
        XCTAssertEqual(model.editState.rotationQuarterTurns, 1)
        model.undo()
        XCTAssertEqual(model.editState.rotationQuarterTurns, 0)
        model.redo()
        XCTAssertEqual(model.editState.rotationQuarterTurns, 1)
    }

    func testRotateLeftFromIdentityStoresThreeTurns() async throws {
        let model = try await makeModel()
        model.rotate(.left)
        XCTAssertEqual(model.editState.rotationQuarterTurns, 3)
        XCTAssertEqual(model.historyEntries.last?.summary, "Rotate Left")
    }

    func testTheCropFollowsAndFourPressesReturnToIdentityIncludingTheCrop() async throws {
        let model = try await makeModel()
        model.editState.cropInsetTop = 0.1
        model.editState.cropInsetLeft = 0.3
        let start = model.editState
        model.rotate(.right)
        XCTAssertEqual(model.editState.cropInsetRight, 0.1, "top -> right")
        XCTAssertEqual(model.editState.cropInsetTop, 0.3, "left -> top")
        for _ in 0..<3 { model.rotate(.right) }
        XCTAssertEqual(model.editState, start)
    }

    func testPendingSliderBurstIsFlushedBeforeTheRotateStep() async throws {
        let model = try await makeModel()
        model.editState.exposureEV = 0.5   // a burst still inside its coalescing window
        model.rotate(.right)
        XCTAssertEqual(model.editState.exposureEV, 0.5)
        XCTAssertEqual(model.historyEntries.last?.summary, "Rotate Right")
        model.undo()
        XCTAssertEqual(model.editState.exposureEV, 0.5, "the exposure burst is its own earlier step")
        XCTAssertEqual(model.editState.rotationQuarterTurns, 0)
    }

    func testRotateWithoutAPhotoDoesNothing() {
        let model = ImageDocumentModel()
        model.rotate(.right)
        XCTAssertEqual(model.editState.rotationQuarterTurns, 0)
        XCTAssertTrue(model.historyEntries.isEmpty)
    }

    func testRotateIsSavedToTheSidecar() async throws {
        let model = try await makeModel(saving: true)
        model.rotate(.right)
        model.flushPendingSidecarSave()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: dir.appendingPathComponent("a.png")) else {
            return XCTFail("the rotation must reach the sidecar")
        }
        XCTAssertEqual(stored.rotationQuarterTurns, 1)
    }

    /// Masks and red-eye points now turn with the picture, so they no longer produce a "do not turn" note.
    func testMasksAndRedEyePointsTurnWithThePictureAndGiveNoHint() async throws {
        let model = try await makeModel()
        let mask = Mask(kind: .radial, centerX: 0.25, centerY: 0.3, radiusX: 0.2, radiusY: 0.35)
        model.editState.masks = [mask]
        model.editState.redEyePoints = [RedEyePoint(x: 0.2, y: 0.7)]
        let before = model.editState
        model.rotate(.right)
        XCTAssertNil(model.rotationHint, "nothing is left behind, so there is nothing to warn about")
        XCTAssertEqual(model.editState.masks[0], mask.rotatedOnScreen(byQuarterTurns: 1))
        XCTAssertEqual(model.editState.redEyePoints[0], RedEyePoint(x: 0.2, y: 0.7).rotatedOnScreen(byQuarterTurns: 1))
        model.rotate(.left)
        XCTAssertNil(model.rotationHint)
        XCTAssertEqual(model.editState.masks[0].centerX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(model.editState.masks[0].radiusX, 0.2)
        XCTAssertEqual(model.editState.redEyePoints[0].y, 0.7, accuracy: 1e-9)
        // One undo step restores the masks and points exactly, not merely approximately.
        model.undo()
        XCTAssertEqual(model.editState.masks[0], mask.rotatedOnScreen(byQuarterTurns: 1))
        model.undo()
        XCTAssertEqual(model.editState.masks, before.masks)
        XCTAssertEqual(model.editState.redEyePoints, before.redEyePoints)
        XCTAssertEqual(model.editState.rotationQuarterTurns, 0)
    }

    func testFourRotatePressesLeaveTheMasksWhereTheyWereWithinFloatingPoint() async throws {
        let model = try await makeModel()
        let mask = Mask(kind: .linear, centerX: 0.6, centerY: 0.4, rotationDegrees: 20, width: 0.3)
        model.editState.masks = [mask]
        model.rotate(.right)
        let steps = model.historyEntries.count
        for _ in 0..<3 { model.rotate(.right) }
        XCTAssertEqual(model.editState.rotationQuarterTurns, 0)
        XCTAssertEqual(model.editState.masks[0].centerX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(model.editState.masks[0].centerY, 0.4, accuracy: 1e-9)
        XCTAssertEqual(model.editState.masks[0].rotationDegrees, 20, accuracy: 1e-9)
        XCTAssertEqual(model.historyEntries.count, steps + 3, "every press is its own step, the fourth included")
    }

    func testHintIsClearedByRevertUndoRedoAndLoad() async throws {
        let model = try await makeModel()
        model.editState.verticalPerspective = 0.2
        model.rotate(.right)
        XCTAssertNotNil(model.rotationHint)
        model.undo()
        XCTAssertNil(model.rotationHint, "undo")
        model.redo()
        XCTAssertNil(model.rotationHint, "redo")
        model.rotate(.right)
        XCTAssertNotNil(model.rotationHint)
        model.revertToOriginal()
        XCTAssertNil(model.rotationHint, "revert")
        model.editState.verticalPerspective = 0.2
        model.rotate(.left)
        XCTAssertNotNil(model.rotationHint)
        await model.load(from: dir.appendingPathComponent("a.png"))
        XCTAssertNil(model.rotationHint, "load")
    }

    func testPerspectiveAndStretchNoteAppearsOnRotate() async throws {
        let model = try await makeModel()
        model.rotate(.right)
        XCTAssertNil(model.rotationHint)
        model.editState.transformAspect = 0.3
        model.rotate(.right)
        XCTAssertEqual(model.rotationHint, "Perspective and Stretch now act on the rotated picture.")
        model.editState.transformAspect = 0
        model.editState.verticalPerspective = 0.2
        model.editState.masks = [Mask()]
        model.rotate(.right)
        XCTAssertEqual(model.rotationHint, "Perspective and Stretch now act on the rotated picture.", "masks add no second sentence")
    }

    func testRotateAvailabilityRule() {
        XCTAssertTrue(RotateAvailability.isEnabled(hasImage: true, loadInFlight: false, renameWorking: false, cullActive: false, showLibrary: false))
        XCTAssertFalse(RotateAvailability.isEnabled(hasImage: false, loadInFlight: false, renameWorking: false, cullActive: false, showLibrary: false))
        XCTAssertFalse(RotateAvailability.isEnabled(hasImage: true, loadInFlight: true, renameWorking: false, cullActive: false, showLibrary: false))
        XCTAssertFalse(RotateAvailability.isEnabled(hasImage: true, loadInFlight: false, renameWorking: true, cullActive: false, showLibrary: false))
        XCTAssertFalse(RotateAvailability.isEnabled(hasImage: true, loadInFlight: false, renameWorking: false, cullActive: true, showLibrary: false))
        XCTAssertFalse(RotateAvailability.isEnabled(hasImage: true, loadInFlight: false, renameWorking: false, cullActive: false, showLibrary: true))
    }

    // MARK: - Crop aspect lock follows the rotation

    func testOddTurnInvertsCustomAndConvertsFixedPresetsToCustom() {
        let custom = CropAspectRotation.lock(after: 1, preset: .custom, customRatio: 2)
        XCTAssertEqual(custom.preset, .custom)
        XCTAssertEqual(custom.customRatio ?? 0, 0.5, accuracy: 1e-12)
        let fixed = CropAspectRotation.lock(after: -1, preset: .ratio16x9, customRatio: nil)
        XCTAssertEqual(fixed.preset, .custom)
        XCTAssertEqual(fixed.customRatio ?? 0, 9.0 / 16.0, accuracy: 1e-12)
        let portrait = CropAspectRotation.lock(after: 3, preset: .ratio4x5, customRatio: nil)
        XCTAssertEqual(portrait.customRatio ?? 0, 1.25, accuracy: 1e-12)
    }

    func testEvenTurnsAndShapeFreePresetsKeepTheLock() {
        for delta in [0, 2, 4, -2] {
            let r = CropAspectRotation.lock(after: delta, preset: .ratio3x2, customRatio: nil)
            XCTAssertEqual(r.preset, .ratio3x2)
            XCTAssertNil(r.customRatio)
        }
        for preset in [CropAspectPreset.freeform, .original, .square] {
            XCTAssertEqual(CropAspectRotation.lock(after: 1, preset: preset, customRatio: nil).preset, preset)
        }
    }

    func testTwoOddTurnsRestoreTheCustomRatio() {
        let once = CropAspectRotation.lock(after: 1, preset: .custom, customRatio: 1.5)
        let twice = CropAspectRotation.lock(after: 1, preset: once.preset, customRatio: once.customRatio)
        XCTAssertEqual(twice.customRatio ?? 0, 1.5, accuracy: 1e-12)
    }

    func testContentViewWiresTheAspectLockAndTheDragReset() throws {
        let text = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(text.contains(".modifier(CropAspectFollowsRotation(turns: document.editState.rotationQuarterTurns"))
        XCTAssertTrue(text.contains(".id(document.editState.rotationQuarterTurns)"), "the crop overlay is recreated per turn count (ends a drag)")
        XCTAssertTrue(text.contains("rotateEnabled: RotateAvailability.isEnabled("))
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("RotateAvailability.isEnabled("))
        XCTAssertEqual(app.components(separatedBy: ".disabled(!canRotate || catalog.editorInfoOpen)").count - 1, 2, "both menu items use the shared rule (and stay off while the Info popover is open)")
        XCTAssertTrue(try source("Sources/UI/CropTabView.swift").contains(".disabled(!rotateEnabled)"))
        XCTAssertTrue(try source("Sources/UI/CropAspectMath.swift").contains("content.onChange(of: turns)"))
    }

    // MARK: - Detectors measure the rotated source

    func testAutoStraightenMeasuresTheRotatedSource() async throws {
        let model = try await makeModel(width: 48, height: 32)
        model.rotate(.right)
        let detector = GatedHorizon()
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await work.value
        XCTAssertEqual(detector.extents, [CGRect(x: 0, y: 0, width: 32, height: 48)], "axes swapped, origin at zero")
    }

    func testAutoStraightenIsUnchangedWithoutRotation() async throws {
        let model = try await makeModel(width: 48, height: 32)
        let detector = GatedHorizon()
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await work.value
        XCTAssertEqual(detector.extents, [CGRect(x: 0, y: 0, width: 48, height: 32)])
    }

    func testAutoStraightenResultIsDroppedIfThePhotoWasRotatedMeanwhile() async throws {
        let model = try await makeModel()
        let detector = GatedHorizon()
        detector.result = .angle(4 * .pi / 180)
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        model.rotate(.right)
        let steps = model.historyEntries.count
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.historyEntries.count, steps)
        XCTAssertEqual(model.straightenMessage, StraightenMessages.rotatedMeanwhile)
    }

    func testAutoUprightMeasuresTheRotatedSource() async throws {
        let model = try await makeModel(width: 48, height: 32)
        model.rotate(.left)
        let detector = GatedUpright()
        model.uprightDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoUpright(.level))
        detector.release()
        await work.value
        XCTAssertEqual(detector.extents, [CGRect(x: 0, y: 0, width: 32, height: 48)])
    }

    func testAutoUprightResultIsDroppedIfThePhotoWasRotatedMeanwhile() async throws {
        let model = try await makeModel()
        let detector = GatedUpright()
        model.uprightDetector = { _ in detector.detectLevelLines() }
        let work = try XCTUnwrap(model.autoUpright(.level))
        model.rotate(.right)
        let steps = model.historyEntries.count
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.historyEntries.count, steps)
        XCTAssertEqual(model.uprightMessage, StraightenMessages.rotatedMeanwhile)
    }

    func testRotateIsRefusedWhileALoadIsInFlight() async throws {
        let model = try await makeModel()
        let url = dir.appendingPathComponent("a.png")
        let load = Task { @MainActor in await model.load(from: url) }
        var spins = 0
        while !model.isLoadInFlight && spins < 1000 { await Task.yield(); spins += 1 }
        XCTAssertTrue(model.isLoadInFlight)
        let steps = model.historyEntries.count
        model.rotate(.right)
        XCTAssertEqual(model.editState.rotationQuarterTurns, 0, "a step would land on the outgoing photo")
        XCTAssertEqual(model.historyEntries.count, steps)
        await load.value
    }

    // MARK: - White balance slow path samples the rotated frame

    /// Left half neutral grey, right half strongly orange. After Rotate Right the left half is the TOP half: a tap at the top
    /// samples grey (WB stays near neutral), a tap at the bottom samples orange (WB moves). Without the rotation in the sampling
    /// state the two taps would swap.
    func testWhiteBalanceTapSamplesTheRotatedPicture() async throws {
        let size = 40
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: size / 2, height: size))
        let orange = CIImage(color: CIColor(red: 0.9, green: 0.55, blue: 0.2)).cropped(to: CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        let url = try writePNG(orange.composited(over: grey), name: "wb.png")
        func tap(u: Double, v: Double) async throws -> (Double, Double) {
            let model = ImageDocumentModel(folderAccess: Access(folder: nil))
            await model.load(from: url)
            model.rotate(.right)
            model.pickWhiteBalance(normalizedX: u, normalizedY: v)
            try await Task.sleep(nanoseconds: 1_000_000_000)   // the solve runs off the main thread
            return (model.editState.whiteBalanceTemperature, model.editState.whiteBalanceTint)
        }
        let top = try await tap(u: 0.5, v: 0.2)
        let bottom = try await tap(u: 0.5, v: 0.8)
        XCTAssertEqual(top.0, 6500, accuracy: 150, "grey: no correction")
        XCTAssertGreaterThan(abs(bottom.0 - 6500), 1000, "orange: a real correction")
    }

    // MARK: - Wiring (source pins)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testResetCropTabResetsTheRotation() throws {
        let text = try source("Sources/UI/ContentView.swift")
        let start = try XCTUnwrap(text.range(of: "private func resetCropTab()"))
        let body = String(text[start.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("document.editState = document.editState.resettingCropTab()"),
                      "Reset goes through the pure helper, which turns masks back with the picture")
        XCTAssertFalse(body.contains("rotationQuarterTurns = 0"), "no direct write that would strand the masks")
        let helper = try source("Sources/EditEngine/QuarterTurn.swift")
        let h = try XCTUnwrap(helper.range(of: "func resettingCropTab()"))
        XCTAssertTrue(String(helper[h.lowerBound...].prefix(300)).contains("settingStoredQuarterTurns(0)"))
    }

    func testCropTabHasBothRotateButtonsAndTheMenuItemsExist() throws {
        let tab = try source("Sources/UI/CropTabView.swift")
        XCTAssertTrue(tab.contains("            rotateRow\n"), "the row is part of the Crop tab's body")
        XCTAssertTrue(tab.contains("document.rotate(direction)") && tab.contains("rotate.left") && tab.contains("rotate.right"))
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("Button(\"Rotate Left\") { document.rotate(.left) }"))
        XCTAssertTrue(app.contains("Button(\"Rotate Right\") { document.rotate(.right) }"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"[\", modifiers: .command)") && app.contains(".keyboardShortcut(\"]\", modifiers: .command)"))
    }

    func testTheWhiteBalanceSlowPathUsesTheSharedSamplingStateNotAnInlineCopy() throws {
        let text = try source("Sources/UI/ImageDocumentModel.swift")
        XCTAssertFalse(text.contains("samplingState.flipVertical = editState.flipVertical"))
        XCTAssertTrue(text.contains("let samplingState = editState.geometryOnlySamplingState()"))
    }
}
