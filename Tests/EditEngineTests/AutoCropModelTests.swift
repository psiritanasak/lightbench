import CoreImage
import XCTest
@testable import PhotoApp

/// `ImageDocumentModel.autoCrop(aspectRatio:)` through its `autoCropMaskProvider` seam, plus source pins for the Crop tab wiring.
@MainActor
final class AutoCropModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    /// A provider that records its calls and blocks until released.
    private final class GatedProvider: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var _calls = 0
        private var _states: [EditState] = []
        private var _extents: [CGRect] = []
        var result: AutoCropMask?
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var states: [EditState] { lock.lock(); defer { lock.unlock() }; return _states }
        var extents: [CGRect] { lock.lock(); defer { lock.unlock() }; return _extents }
        func measure(_ image: CIImage, _ state: EditState) -> AutoCropMask? {
            lock.lock(); _calls += 1; _states.append(state); _extents.append(image.extent); let r = result; lock.unlock()
            gate.wait()
            return r
        }
        func release() { gate.signal() }
    }

    /// 20x20 mask with an empty 4x4 top-left corner: solves to a crop on one side.
    private static let cornerMask: AutoCropMask = {
        var valid = [Bool](repeating: true, count: 400)
        for y in 0..<4 { for x in 0..<4 { valid[y * 20 + x] = false } }
        return AutoCropMask(width: 20, height: 20, valid: valid)
    }()
    private static let fullMask = AutoCropMask(width: 20, height: 20, valid: [Bool](repeating: true, count: 400))

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AutoCropModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writePNG(_ image: CIImage, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
        return url
    }

    private func makeModel(name: String = "a.png") async throws -> ImageDocumentModel {
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 32))
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: try writePNG(base, name: name))
        return model
    }

    private func install(_ provider: GatedProvider, on model: ImageDocumentModel) {
        model.autoCropMaskProvider = { provider.measure($0, $1) }
    }

    func testWithoutAnImageItOnlyExplains() {
        let model = ImageDocumentModel()
        XCTAssertNil(model.autoCrop(aspectRatio: nil))
        XCTAssertFalse(model.isAutoCropping)
        XCTAssertNotNil(model.autoCropMessage)
        XCTAssertTrue(model.historyEntries.isEmpty)
    }

    func testCropIsOneUndoStepAndReplacesAnExistingCrop() async throws {
        let model = try await makeModel()
        model.editState.straightenAngle = 5
        model.editState.cropInsetRight = 0.3 // an existing crop is replaced, not combined
        let provider = GatedProvider()
        provider.result = Self.cornerMask
        install(provider, on: model)
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        provider.release()
        await work.value
        let next = model.editState
        XCTAssertEqual(next.cropInsetRight, 0)
        XCTAssertEqual(next.cropInsetBottom, 0)
        XCTAssertGreaterThan(max(next.cropInsetTop, next.cropInsetLeft), 0.25)
        XCTAssertEqual(model.historyEntries.last?.summary, "Auto Crop")
        let entries = model.historyEntries.count
        model.undo()
        XCTAssertEqual(model.historyEntries.count, entries)
        XCTAssertEqual(model.editState.cropInsetRight, 0.3, "undo restores the old crop in ONE step")
        XCTAssertEqual(model.editState.cropInsetTop, 0)
        XCTAssertEqual(model.editState.straightenAngle, 5)
        XCTAssertNil(model.autoCropMessage)
    }

    func testMeasurementIgnoresTheCropAndGetsTheRenderableImage() async throws {
        let model = try await makeModel()
        model.editState.straightenAngle = 5
        model.editState.cropInsetTop = 0.2
        let provider = GatedProvider()
        provider.result = Self.fullMask
        install(provider, on: model)
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        provider.release()
        await work.value
        XCTAssertEqual(provider.extents, [CGRect(x: 0, y: 0, width: 48, height: 32)], "the unedited source, not a cropped or rendered image")
        XCTAssertEqual(provider.states.first?.straightenAngle, 5)
    }

    func testNothingToCropOnlyExplains() async throws {
        let model = try await makeModel()
        let entries = model.historyEntries.count
        let provider = GatedProvider()
        provider.result = Self.fullMask
        install(provider, on: model)
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        provider.release()
        await work.value
        XCTAssertEqual(model.autoCropMessage, AutoCropMessages.nothingToCrop)
        XCTAssertEqual(model.historyEntries.count, entries)
        XCTAssertEqual(model.editState.cropInsetTop, 0)
    }

    func testTooLargeAndUnmeasurableOnlyExplain() async throws {
        let model = try await makeModel()
        let entries = model.historyEntries.count
        let provider = GatedProvider()
        install(provider, on: model)
        provider.result = AutoCropMask(width: 20, height: 20, valid: (0..<400).map { $0 % 20 >= 12 })
        var work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        provider.release()
        await work.value
        XCTAssertEqual(model.autoCropMessage, AutoCropMessages.tooLarge)
        provider.result = nil
        work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        provider.release()
        await work.value
        XCTAssertEqual(model.autoCropMessage, AutoCropMessages.unmeasurable)
        XCTAssertEqual(model.historyEntries.count, entries)
    }

    func testRepeatPressWhenTheCropAlreadyFitsAddsNoStep() async throws {
        let model = try await makeModel()
        let provider = GatedProvider()
        provider.result = Self.cornerMask
        install(provider, on: model)
        var work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        provider.release()
        await work.value
        let entries = model.historyEntries.count
        work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        provider.release()
        await work.value
        XCTAssertEqual(model.historyEntries.count, entries)
        XCTAssertEqual(model.autoCropMessage, AutoCropMessages.alreadyApplied)
    }

    func testDoubleClickRunsTheMeasurementOnce() async throws {
        let model = try await makeModel()
        let provider = GatedProvider()
        provider.result = Self.cornerMask
        install(provider, on: model)
        let first = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        XCTAssertTrue(model.isAutoCropping)
        XCTAssertNil(model.autoCrop(aspectRatio: nil), "a second press while running must be ignored")
        provider.release()
        await first.value
        XCTAssertEqual(provider.calls, 1)
        XCTAssertFalse(model.isAutoCropping)
    }

    func testAutoStraightenAndUprightAreBlockedWhileCroppingAndViceVersa() async throws {
        let model = try await makeModel()
        let provider = GatedProvider()
        provider.result = Self.cornerMask
        install(provider, on: model)
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        XCTAssertNil(model.autoStraighten())
        XCTAssertNil(model.autoUpright(.level))
        provider.release()
        await work.value
        // And the other way round: Straighten running blocks Auto Crop.
        let gate = DispatchSemaphore(value: 0)
        model.horizonDetector = { _ in gate.wait(); return .none }
        let straighten = try XCTUnwrap(model.autoStraighten())
        XCTAssertNil(model.autoCrop(aspectRatio: nil))
        gate.signal()
        await straighten.value
    }

    func testResultForAPhotoThatWasSwitchedAwayFromIsDropped() async throws {
        let model = try await makeModel()
        let provider = GatedProvider()
        provider.result = Self.cornerMask
        install(provider, on: model)
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        let other = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        await model.load(from: try writePNG(other, name: "b.png"))
        let entries = model.historyEntries.count
        provider.release()
        await work.value
        XCTAssertEqual(model.editState.cropInsetTop, 0)
        XCTAssertEqual(model.editState.cropInsetLeft, 0)
        XCTAssertEqual(model.historyEntries.count, entries)
        XCTAssertNil(model.autoCropMessage)
        XCTAssertFalse(model.isAutoCropping)
    }

    func testResultArrivingWhileAnotherLoadIsInFlightIsDropped() async throws {
        let model = try await makeModel()
        let provider = GatedProvider()
        provider.result = Self.cornerMask
        install(provider, on: model)
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        let url = dir.appendingPathComponent("a.png")
        let load = Task { @MainActor in await model.load(from: url) }
        var spins = 0
        while !model.isLoadInFlight && spins < 1000 { await Task.yield(); spins += 1 }
        XCTAssertTrue(model.isLoadInFlight, "the load must be mid-flight when the result lands")
        provider.release()
        await work.value
        XCTAssertEqual(model.editState.cropInsetTop, 0)
        XCTAssertEqual(model.editState.cropInsetLeft, 0)
        XCTAssertNil(model.autoCropMessage)
        await load.value
    }

    func testGeometryChangedMeanwhileChangesNothing() async throws {
        for edit: (inout EditState) -> Void in [
            { $0.straightenAngle = 9 }, { $0.verticalPerspective = 0.2 }, { $0.horizontalPerspective = 0.2 },
            { $0.transformScale = 0.9 }, { $0.transformAspect = 0.3 }, { $0.flipHorizontal = true },
            { $0.flipVertical = true }, { $0.rotationQuarterTurns = 1 }
        ] {
            let model = try await makeModel()
            let provider = GatedProvider()
            provider.result = Self.cornerMask
            install(provider, on: model)
            let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
            edit(&model.editState)
            let entries = model.historyEntries.count
            provider.release()
            await work.value
            XCTAssertEqual(model.editState.cropInsetTop, 0)
            XCTAssertEqual(model.editState.cropInsetLeft, 0)
            XCTAssertEqual(model.autoCropMessage, AutoCropMessages.changedMeanwhile)
            XCTAssertGreaterThanOrEqual(model.historyEntries.count, entries)
            XCTAssertNotEqual(model.historyEntries.last?.summary, "Auto Crop")
        }
    }

    func testANonGeometryEditDuringMeasuringSurvivesAndTheCropIsOneMoreStep() async throws {
        let model = try await makeModel()
        let provider = GatedProvider()
        provider.result = Self.cornerMask
        install(provider, on: model)
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        model.editState.exposureEV = 0.5
        provider.release()
        await work.value
        XCTAssertEqual(model.editState.exposureEV, 0.5)
        XCTAssertEqual(model.historyEntries.last?.summary, "Auto Crop")
        XCTAssertEqual(model.historyEntries.dropLast().last?.summary.contains("Exposure"), true)
    }

    func testALockedAspectResultHasTheRequestedRatio() async throws {
        let model = try await makeModel()
        let provider = GatedProvider()
        provider.result = Self.cornerMask
        install(provider, on: model)
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: 2))
        provider.release()
        await work.value
        let s = model.editState
        let w = (1 - s.cropInsetLeft - s.cropInsetRight) * 20, h = (1 - s.cropInsetTop - s.cropInsetBottom) * 20
        XCTAssertEqual(w / h, 2, accuracy: 1e-9)
    }

    func testPhotoSwitchClearsALateMessage() async throws {
        let model = try await makeModel()
        model.autoCropMessage = "stale"
        let other = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        await model.load(from: try writePNG(other, name: "c.png"))
        XCTAssertNil(model.autoCropMessage)
    }

    // MARK: Real measurement end to end

    func testRealMeasurementOnAStraightenedPhotoCropsAwayEveryEmptyCorner() async throws {
        let model = try await makeModel()
        model.editState.straightenAngle = 8
        let work = try XCTUnwrap(model.autoCrop(aspectRatio: nil))
        await work.value
        XCTAssertNil(model.autoCropMessage)
        XCTAssertEqual(model.historyEntries.last?.summary, "Auto Crop")
        let s = model.editState
        XCTAssertGreaterThan(s.cropInsetTop, 0)
        let source = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 32))
        let output = EditPipeline.apply(s, to: source)
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(output, toBitmap: &bytes, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var transparent = 0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) where bytes[(y * w + x) * 4 + 3] < 255 { transparent += 1 } }
        XCTAssertEqual(transparent, 0)
    }

    // MARK: Wiring pins

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheCropTabHasAnAutoCropButtonDisabledWhileAnotherAutoToolRuns() throws {
        let tab = try source("Sources/UI/CropTabView.swift")
        XCTAssertTrue(tab.contains("document.autoCrop(aspectRatio: autoCropAspectRatio())"), "the button must pass the selected aspect")
        XCTAssertTrue(tab.contains("Auto Crop"))
        for guardText in ["document.isAutoCropping", "document.isAutoStraightening", "document.isAutoUprighting"] {
            XCTAssertGreaterThanOrEqual(tab.components(separatedBy: guardText).count - 1, 3, "\(guardText) must gate Auto Crop, Auto and Upright")
        }
        XCTAssertTrue(tab.contains("document.autoCropMessage"), "outcomes that change nothing are shown in an alert")
    }

    func testContentViewPassesTheEffectiveAspectRatioToTheCropTab() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("autoCropAspectRatio: { effectiveAspectRatio }"))
        XCTAssertFalse(content.contains("does not auto-crop"), "the reset comment must no longer say Auto never crops")
    }
}
