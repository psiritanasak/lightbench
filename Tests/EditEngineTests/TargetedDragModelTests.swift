import XCTest
import CoreImage
@testable import PhotoApp

/// `ImageDocumentModel`'s Targeted adjustment drag API end to end through a real loaded photo, with the sampler replaced by the
/// `targetSampler` seam so no pixels are read.
@MainActor
final class TargetedDragModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TargetedDragModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel(sample: (r: Double, g: Double, b: Double)?) async throws -> (ImageDocumentModel, Recorder) {
        let url = dir.appendingPathComponent("photo.png")
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: url)
        let recorder = Recorder()
        model.targetSampler = { truncation, u, v in
            recorder.calls.append((truncation, u, v))
            return sample
        }
        return (model, recorder)
    }

    private final class Recorder { var calls: [(EditPipeline.ColorSampleTruncation, Double, Double)] = [] }

    // MARK: - Curve

    func testCurveDragIsOneLabelledUndoStepEvenWhenSlow() async throws {
        let (model, recorder) = try await makeModel(sample: (0.5, 0.5, 0.5))
        let steps = model.historyEntries.count
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.4, normalizedY: 0.6))
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].0, .beforePointCurve)
        XCTAssertEqual(recorder.calls[0].1, 0.4)
        XCTAssertEqual(recorder.calls[0].2, 0.6)
        for step in 1...6 {
            model.updateTargetedDrag(delta: Double(step) * 0.03)
            // Longer than the 350 ms coalescing window: a normal edit would have committed a step by now.
            try await Task.sleep(nanoseconds: 450_000_000)
            XCTAssertEqual(model.historyEntries.count, steps, "no step may land mid-drag (step \(step))")
        }
        model.endTargetedDrag()
        XCTAssertEqual(model.historyEntries.count, steps + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Targeted Curve")
        XCTAssertEqual(recorder.calls.count, 1, "sampled once, at drag start only")
        let points = model.editState.toneCurvePoints
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[1].y, PerceptualEncoding.srgbEncode(0.5) + 0.18, accuracy: 0.02)
        model.undo()
        XCTAssertEqual(model.editState.toneCurvePoints, [], "one undo restores the pre-drag curve")
    }

    func testRealTimeSecondsLaterNoExtraStepAppears() async throws {
        let (model, _) = try await makeModel(sample: (0.5, 0.5, 0.5))
        let steps = model.historyEntries.count
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.2)
        model.endTargetedDrag()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.historyEntries.count, steps + 1, "the debounced burst must not add a second step")
    }

    func testZeroNetDragLeavesNoHistoryStep() async throws {
        let (model, _) = try await makeModel(sample: (0.5, 0.5, 0.5))
        let steps = model.historyEntries.count
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.2)
        model.updateTargetedDrag(delta: 0)
        model.endTargetedDrag()
        XCTAssertEqual(model.historyEntries.count, steps)
        XCTAssertEqual(model.editState.toneCurvePoints, [])
    }

    func testCancelRestoresTheDragStartState() async throws {
        let (model, _) = try await makeModel(sample: (0.5, 0.5, 0.5))
        model.editState.contrast = 0.3
        try await Task.sleep(nanoseconds: 500_000_000)
        let steps = model.historyEntries.count
        let before = model.editState
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.3)
        XCTAssertNotEqual(model.editState, before)
        model.cancelTargetedDrag()
        XCTAssertEqual(model.editState, before)
        XCTAssertEqual(model.historyEntries.count, steps)
        XCTAssertFalse(model.isTargetedDragActive)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.historyEntries.count, steps, "a cancelled drag leaves nothing to commit later")
    }

    func testPendingBurstBeforeTheDragIsItsOwnStep() async throws {
        let (model, _) = try await makeModel(sample: (0.5, 0.5, 0.5))
        let steps = model.historyEntries.count
        model.editState.contrast = 0.4 // burst still pending
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.2)
        model.endTargetedDrag()
        XCTAssertEqual(model.historyEntries.count, steps + 2)
        XCTAssertEqual(model.historyEntries.last?.summary, "Targeted Curve")
        model.undo()
        XCTAssertEqual(model.editState.contrast, 0.4)
        XCTAssertEqual(model.editState.toneCurvePoints, [])
    }

    // MARK: - Colour

    func testSelectiveColorSaturationDragMovesTheBandUnderThePixel() async throws {
        // A saturated red sample (perceptual).
        let (model, recorder) = try await makeModel(sample: (0.8, 0.2, 0.2))
        XCTAssertTrue(model.beginTargetedDrag(tool: .selectiveColor(.saturation), normalizedX: 0.5, normalizedY: 0.5))
        XCTAssertEqual(recorder.calls[0].0, .beforeSelectiveColor)
        model.updateTargetedDrag(delta: 0.4)
        model.endTargetedDrag()
        XCTAssertEqual(model.editState.redSaturation, 0.4, accuracy: 1e-9)
        XCTAssertEqual(model.editState.greenSaturation, 0)
        XCTAssertEqual(model.editState.redHue, 0)
        XCTAssertEqual(model.historyEntries.last?.summary, "Targeted Saturation")
    }

    func testDraggingDownLowersAndClamps() async throws {
        let (model, _) = try await makeModel(sample: (0.8, 0.2, 0.2))
        XCTAssertTrue(model.beginTargetedDrag(tool: .selectiveColor(.luminance), normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: -3)
        model.endTargetedDrag()
        XCTAssertEqual(model.editState.redLuminance, -1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Targeted Luminance")
    }

    func testUpdatesAreRelativeToTheDragStartNotCumulative() async throws {
        let (model, _) = try await makeModel(sample: (0.8, 0.2, 0.2))
        model.editState.redHue = 0.5
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(model.beginTargetedDrag(tool: .selectiveColor(.hue), normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.2)
        model.updateTargetedDrag(delta: 0.1)
        XCTAssertEqual(model.editState.redHue, 0.6, accuracy: 1e-9, "start 0.5 + the CURRENT delta 0.1")
        model.endTargetedDrag()
    }

    func testNeutralPixelStartsNoDrag() async throws {
        let (model, _) = try await makeModel(sample: (0.5, 0.5, 0.5))
        XCTAssertFalse(model.beginTargetedDrag(tool: .selectiveColor(.hue), normalizedX: 0.5, normalizedY: 0.5))
        XCTAssertFalse(model.isTargetedDragActive)
        XCTAssertFalse(model.beginTargetedDrag(tool: .grayMix, normalizedX: 0.5, normalizedY: 0.5))
    }

    func testGrayMixDragChangesTheMixBand() async throws {
        let (model, recorder) = try await makeModel(sample: (0.2, 0.3, 0.8)) // blue
        model.editState.blackAndWhite = true
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(model.beginTargetedDrag(tool: .grayMix, normalizedX: 0.5, normalizedY: 0.5))
        XCTAssertEqual(recorder.calls[0].0, .beforeGrayMix)
        model.updateTargetedDrag(delta: -0.5)
        model.endTargetedDrag()
        XCTAssertEqual(model.editState.grayMixBlue, -0.5, accuracy: 1e-9)
        XCTAssertEqual(model.editState.grayMixRed, 0)
        XCTAssertEqual(model.historyEntries.last?.summary, "Targeted B&W Mix")
    }

    // MARK: - Guards

    func testRefusedAwayFromIdentityGeometry() async throws {
        let (model, recorder) = try await makeModel(sample: (0.5, 0.5, 0.5))
        model.editState.straightenAngle = 3
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        XCTAssertTrue(recorder.calls.isEmpty, "no sampling when the geometry makes it inexact")
    }

    func testUnreadableSampleStartsNoDrag() async throws {
        let (model, _) = try await makeModel(sample: nil)
        XCTAssertFalse(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
    }

    func testASecondBeginWhileDraggingIsRefused() async throws {
        let (model, recorder) = try await makeModel(sample: (0.5, 0.5, 0.5))
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        XCTAssertFalse(model.beginTargetedDrag(tool: .curve, normalizedX: 0.2, normalizedY: 0.5))
        XCTAssertEqual(recorder.calls.count, 1)
        model.endTargetedDrag()
    }

    func testUpdateAndEndWithoutADragAreNoOps() async throws {
        let (model, _) = try await makeModel(sample: (0.5, 0.5, 0.5))
        let steps = model.historyEntries.count
        let state = model.editState
        model.updateTargetedDrag(delta: 0.5)
        model.endTargetedDrag()
        model.cancelTargetedDrag()
        XCTAssertEqual(model.editState, state)
        XCTAssertEqual(model.historyEntries.count, steps)
    }

    func testNonFiniteDeltaIsIgnored() async throws {
        let (model, _) = try await makeModel(sample: (0.8, 0.2, 0.2))
        XCTAssertTrue(model.beginTargetedDrag(tool: .selectiveColor(.hue), normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: .nan)
        XCTAssertEqual(model.editState.redHue, 0)
        model.endTargetedDrag()
    }
}
