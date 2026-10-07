import CoreImage
import XCTest
@testable import PhotoApp

/// `ImageDocumentModel.setProtectSkin` / `resetStyle`'s protection clearing, with an injected detector (no Vision).
@MainActor
final class StyleSkinProtectionModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private var dir: URL!
    private let png = Data((0..<500).map { UInt8(truncatingIfNeeded: $0) })

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("StyleSkinModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writePhoto(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return url
    }

    private func makeModel(_ result: SkinMaskGenerator.Result, delay: TimeInterval = 0, counter: Counter = Counter()) async throws -> ImageDocumentModel {
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        model.skinMaskGenerator = { _ in
            counter.bump()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return result
        }
        await model.load(from: try writePhoto("photo.png"))
        return model
    }

    private func waitForDetection(_ model: ImageDocumentModel) async {
        let deadline = Date().addingTimeInterval(5)
        while model.isDetectingSkin, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isDetectingSkin, "detection did not finish")
    }

    func testTurningOnCommitsOneLabelledStepWithTheRasterAndRevisionAndUndoRemovesAll() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1))
        let before = model.historyEntries.count
        model.setProtectSkin(true)
        XCTAssertTrue(model.isDetectingSkin, "busy is visible immediately")
        await waitForDetection(model)
        XCTAssertTrue(model.editState.styleProtectSkin)
        XCTAssertEqual(model.editState.styleSkinMaskPNG, png)
        XCTAssertEqual(model.editState.styleSkinMaskRevision, 1)
        XCTAssertEqual(model.historyEntries.count, before + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Protect Skin: On")
        XCTAssertNil(model.skinProtectionMessage)
        model.undo()
        XCTAssertFalse(model.editState.styleProtectSkin)
        XCTAssertNil(model.editState.styleSkinMaskPNG)
        XCTAssertNil(model.editState.styleSkinMaskRevision)
    }

    func testNoPeopleLeavesProtectionOffAddsNoStepAndSaysWhy() async throws {
        let model = try await makeModel(.noPeople)
        let before = model.historyEntries.count
        model.setProtectSkin(true)
        await waitForDetection(model)
        XCTAssertFalse(model.editState.styleProtectSkin)
        XCTAssertNil(model.editState.styleSkinMaskPNG)
        XCTAssertEqual(model.historyEntries.count, before)
        XCTAssertEqual(model.skinProtectionMessage, "No people found in this photo — nothing to protect.")
    }

    func testAFailureReportsItsReasonAndChangesNothing() async throws {
        let model = try await makeModel(.failed("Person detection failed: boom"))
        let before = model.historyEntries.count
        model.setProtectSkin(true)
        await waitForDetection(model)
        XCTAssertEqual(model.skinProtectionMessage, "Person detection failed: boom")
        XCTAssertEqual(model.historyEntries.count, before)
        XCTAssertFalse(model.editState.styleProtectSkin)
    }

    func testTurningOffClearsRasterRevisionAndAmountInOneStepAndUndoRestoresThem() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1))
        model.setProtectSkin(true)
        await waitForDetection(model)
        model.editState.styleProtectAmount = 0.4
        model.setProtectSkin(false)
        XCTAssertFalse(model.editState.styleProtectSkin)
        XCTAssertNil(model.editState.styleSkinMaskPNG)
        XCTAssertNil(model.editState.styleSkinMaskRevision)
        XCTAssertEqual(model.editState.styleProtectAmount, 1, "an amount without protection would be an invisible edit")
        XCTAssertEqual(model.historyEntries.last?.summary, "Protect Skin: Off")
        XCTAssertTrue(model.editState.isEffectivelyIdentity, "nothing stranded: the photo reads as untouched again")
        model.undo()
        XCTAssertTrue(model.editState.styleProtectSkin)
        XCTAssertEqual(model.editState.styleSkinMaskPNG, png)
        XCTAssertEqual(model.editState.styleProtectAmount, 0.4)
    }

    func testTurningOffWhenNothingIsSetIsANoOp() async throws {
        let model = try await makeModel(.noPeople)
        let before = model.historyEntries.count
        model.setProtectSkin(false)
        XCTAssertEqual(model.historyEntries.count, before)
    }

    func testASecondRequestWhileDetectingIsIgnored() async throws {
        let counter = Counter()
        let model = try await makeModel(.mask(png: png, revision: 1), delay: 0.3, counter: counter)
        model.setProtectSkin(true)
        model.setProtectSkin(true)
        await waitForDetection(model)
        XCTAssertEqual(counter.value, 1)
        model.setProtectSkin(true) // already on: also a no-op
        XCTAssertEqual(counter.value, 1)
    }

    func testAResultThatArrivesAfterAPhotoSwitchIsDropped() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1), delay: 0.4)
        model.setProtectSkin(true)
        await model.load(from: try writePhoto("other.png"))
        await waitForDetection(model)
        XCTAssertFalse(model.editState.styleProtectSkin, "the other photo must not inherit the first photo's skin raster")
        XCTAssertNil(model.editState.styleSkinMaskPNG)
    }

    func testAPhotoSwitchClearsALateMessage() async throws {
        let model = try await makeModel(.noPeople)
        model.setProtectSkin(true)
        await waitForDetection(model)
        XCTAssertNotNil(model.skinProtectionMessage)
        await model.load(from: try writePhoto("other.png"))
        XCTAssertNil(model.skinProtectionMessage)
    }

    /// Switching protection off while a detection is still running (e.g. via the model API or a menu) must cancel its landing.
    func testTurningOffWhileDetectingStopsTheLateResultFromTurningItOn() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1), delay: 0.3)
        model.setProtectSkin(true)
        model.setProtectSkin(false)
        await waitForDetection(model)
        XCTAssertFalse(model.editState.styleProtectSkin)
        XCTAssertNil(model.editState.styleSkinMaskPNG)
    }

    func testRevertToOriginalCancelsARunningDetectionAndStaysTrueIdentity() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1), delay: 0.3)
        model.setProtectSkin(true)
        model.revertToOriginal()
        await waitForDetection(model)
        XCTAssertTrue(model.editState.isEffectivelyIdentity, "Revert must end at true identity, with no late raster")
    }

    func testCancelPendingSkinDetectionDropsTheLateResultWhichIsWhatResetAdjustmentsCalls() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1), delay: 0.3)
        model.setProtectSkin(true)
        model.cancelPendingSkinDetection()
        await waitForDetection(model)
        XCTAssertFalse(model.editState.styleProtectSkin)
        XCTAssertNil(model.editState.styleSkinMaskPNG)
    }

    func testResetStyleClearsProtectionAndStopsARunningDetectionFromTurningItBackOn() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1), delay: 0.3)
        model.setProtectSkin(true)
        model.resetStyle() // nothing else is set: no history step, but the running detection must be cancelled
        await waitForDetection(model)
        XCTAssertFalse(model.editState.styleProtectSkin)

        let model2 = try await makeModel(.mask(png: png, revision: 1))
        model2.selectStyle("builtin:honey")
        model2.setProtectSkin(true)
        await waitForDetection(model2)
        XCTAssertTrue(model2.editState.styleProtectSkin)
        model2.resetStyle()
        XCTAssertEqual(model2.editState.styleID, "")
        XCTAssertFalse(model2.editState.styleProtectSkin)
        XCTAssertNil(model2.editState.styleSkinMaskPNG)
        XCTAssertNil(model2.editState.styleSkinMaskRevision)
        XCTAssertEqual(model2.editState.styleProtectAmount, 1)
        XCTAssertEqual(model2.historyEntries.last?.summary, "Reset Style")
    }

    // MARK: - Reset Look & Style (the Looks tab's reset)

    func testResetLookAndStyleIsOneLabelledUndoableStepThatKeepsTheSliders() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1))
        model.selectStyle("builtin:honey")
        model.setProtectSkin(true)
        await waitForDetection(model)
        model.editState.lookID = BuiltInLooks.all[0].id
        model.editState.lookIntensity = 0.5
        model.editState.exposureEV = 0.3
        let styled = model.editState // the reset flushes the pending slider burst first, then adds exactly ONE step on top
        model.resetLookAndStyle()
        XCTAssertTrue(model.editState.isLookAndStyleAtIdentity)
        XCTAssertEqual(model.editState.exposureEV, 0.3, "sliders are not touched")
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Look & Style")
        XCTAssertEqual(model.historyEntries.dropLast().last?.state, styled, "one step: the entry before it is the styled state")
        model.undo()
        XCTAssertEqual(model.editState, styled)
    }

    func testResetLookAndStyleAtIdentityAddsNoStep() async throws {
        let model = try await makeModel(.noPeople)
        model.editState.exposureEV = 0.3
        model.resetLookAndStyle() // flushes the exposure burst; the reset itself has nothing to do
        XCTAssertNotEqual(model.historyEntries.last?.summary, "Reset Look & Style")
        XCTAssertEqual(model.historyEntries.last?.state.exposureEV, 0.3)
    }

    func testResetLookAndStyleCancelsARunningDetection() async throws {
        let model = try await makeModel(.mask(png: png, revision: 1), delay: 0.3)
        model.setProtectSkin(true)
        model.resetLookAndStyle()
        await waitForDetection(model)
        XCTAssertFalse(model.editState.styleProtectSkin)
        XCTAssertNil(model.editState.styleSkinMaskPNG)
    }

    /// The Style section's own Reset must clear the style but leave the Look alone (it shares the field list with
    /// `resetLookAndStyle`, minus the look fields).
    func testResetStyleKeepsTheLook() async throws {
        let model = try await makeModel(.noPeople)
        model.selectStyle("builtin:honey")
        model.editState.lookID = BuiltInLooks.all[0].id
        model.editState.lookIntensity = 0.5
        model.resetStyle()
        XCTAssertEqual(model.editState.styleID, "")
        XCTAssertEqual(model.editState.lookID, BuiltInLooks.all[0].id)
        XCTAssertEqual(model.editState.lookIntensity, 0.5)
        XCTAssertEqual(model.historyEntries.last?.summary, "Reset Style")
    }
}
