import CoreImage
import XCTest
@testable import PhotoApp

/// `ImageDocumentModel.autoUpright(_:)` through its `uprightDetector` seam, on small temp PNGs (never a real
/// folder: the sidecar folder-access prompt is declined).
@MainActor
final class UprightModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    /// A detector that records what it was given and blocks until released.
    private final class GatedDetector: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var _calls = 0
        private var _extents: [CGRect] = []
        var result: UprightDetector.Result = .lines(UprightModelTests.levelLines(ccwTilt: 0))
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var extents: [CGRect] { lock.lock(); defer { lock.unlock() }; return _extents }
        func detect(_ image: CIImage) -> UprightDetector.Result {
            lock.lock(); _calls += 1; _extents.append(image.extent); let r = result; lock.unlock()
            gate.wait()
            return r
        }
        func release() { gate.signal() }
    }

    // MARK: Fixtures

    /// Two near-horizontal lines rotated `ccwTilt` degrees counter-clockwise: Level solves to `-ccwTilt`.
    nonisolated static func levelLines(ccwTilt: Double) -> UprightLineDetector.Lines {
        let lines = [-8.0, 8.0].map { UprightLineDetector.Line(theta: .pi / 2 - ccwTilt * .pi / 180, rho: $0, span: 40, votes: 100) }
        return UprightLineDetector.Lines(width: 48, height: 32, vertical: [], horizontal: lines)
    }

    /// Two vertical lines converging at the top (vanishing point 100 px above the centre of a 48x32 frame):
    /// k = (100 - 16) / (100 + 16), Vertical solves to about -0.55.
    nonisolated static func convergingLines() -> UprightLineDetector.Lines {
        let lines = [-15.0, 15.0].map { a -> UprightLineDetector.Line in
            let theta = atan((0 - a) / 100)
            return UprightLineDetector.Line(theta: theta, rho: a * cos(theta), span: 30, votes: 100)
        }
        return UprightLineDetector.Lines(width: 48, height: 32, vertical: lines, horizontal: [])
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("UprightModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writePNG(_ image: CIImage, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
        return url
    }

    private func makeModel(width: Int = 48, height: Int = 32, name: String = "a.png") async throws -> ImageDocumentModel {
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: try writePNG(base, name: name))
        return model
    }

    private func gated(_ model: ImageDocumentModel, _ result: UprightDetector.Result) -> GatedDetector {
        let detector = GatedDetector()
        detector.result = result
        model.uprightDetector = { detector.detect($0) }
        return detector
    }

    // MARK: Guards

    func testWithoutAnImageDoesNothingButExplain() {
        let model = ImageDocumentModel()
        XCTAssertNil(model.autoUpright(.level))
        XCTAssertFalse(model.isAutoUprighting)
        XCTAssertNotNil(model.uprightMessage)
        XCTAssertTrue(model.historyEntries.isEmpty)
    }

    func testDoubleClickRunsTheDetectorOnce() async throws {
        let model = try await makeModel()
        let detector = gated(model, .lines(Self.levelLines(ccwTilt: 4)))
        let first = try XCTUnwrap(model.autoUpright(.level))
        XCTAssertTrue(model.isAutoUprighting)
        XCTAssertNil(model.autoUpright(.vertical), "a second press while running must be ignored")
        detector.release()
        await first.value
        XCTAssertEqual(detector.calls, 1)
        XCTAssertFalse(model.isAutoUprighting)
    }

    func testResultForAPhotoThatWasSwitchedAwayFromIsDropped() async throws {
        let model = try await makeModel()
        let detector = gated(model, .lines(Self.levelLines(ccwTilt: 4)))
        let work = try XCTUnwrap(model.autoUpright(.level))
        let other = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        await model.load(from: try writePNG(other, name: "b.png")) // bumps analysisGeneration
        let entries = model.historyEntries.count
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.historyEntries.count, entries)
        XCTAssertNil(model.uprightMessage)
    }

    func testResultArrivingWhileAnotherLoadIsInFlightIsDropped() async throws {
        let model = try await makeModel()
        let detector = gated(model, .lines(Self.levelLines(ccwTilt: 4)))
        let work = try XCTUnwrap(model.autoUpright(.level))
        let url = dir.appendingPathComponent("a.png")
        let load = Task { @MainActor in await model.load(from: url) }
        var spins = 0
        while !model.isLoadInFlight && spins < 1000 { await Task.yield(); spins += 1 }
        XCTAssertTrue(model.isLoadInFlight, "the load must be mid-flight when the result lands")
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertNil(model.uprightMessage)
        await load.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
    }

    func testPhotoSwitchClearsALateMessage() async throws {
        let model = try await makeModel()
        model.uprightMessage = "stale"
        let other = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        await model.load(from: try writePNG(other, name: "c.png"))
        XCTAssertNil(model.uprightMessage)
    }

    // MARK: Applying

    func testSliderEditDuringDetectionSurvivesAndTheResultIsOneUndoStep() async throws {
        let model = try await makeModel()
        let detector = gated(model, .lines(Self.levelLines(ccwTilt: 4)))
        let work = try XCTUnwrap(model.autoUpright(.level))
        model.editState.exposureEV = 0.5 // a burst still inside its coalescing window
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.exposureEV, 0.5)
        XCTAssertEqual(model.editState.straightenAngle, -4)
        XCTAssertEqual(model.historyEntries.last?.summary, "Upright Level")
        XCTAssertEqual(model.historyEntries.dropLast().last?.summary.contains("Exposure"), true,
                       "the exposure burst is its own entry; Upright is exactly one more")
        model.undo()
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.editState.exposureEV, 0.5)
    }

    func testDetectorReceivesTheUneditedSourceEvenWithGeometrySet() async throws {
        let model = try await makeModel(width: 48, height: 32)
        model.editState.flipHorizontal = true
        model.editState.transformAspect = 1
        model.editState.straightenAngle = 10 // would grow the extent if the pipeline were applied
        model.editState.verticalPerspective = 0.3
        model.editState.cropInsetLeft = 0.25
        let detector = gated(model, .failed("stop"))
        let work = try XCTUnwrap(model.autoUpright(.vertical))
        detector.release()
        await work.value
        XCTAssertEqual(detector.extents, [CGRect(x: 0, y: 0, width: 48, height: 32)])
    }

    func testVerticalSetsStraightenAndKeystoneAndClearsHorizontalAsOneStep() async throws {
        let model = try await makeModel()
        model.editState.horizontalPerspective = 0.4
        model.editState.exposureEV = 0.2
        let detector = gated(model, .lines(Self.convergingLines()))
        let work = try XCTUnwrap(model.autoUpright(.vertical))
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.verticalPerspective, -0.55, accuracy: 0.011)
        XCTAssertEqual(model.editState.horizontalPerspective, 0)
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.editState.exposureEV, 0.2, "everything else is untouched")
        XCTAssertEqual(model.historyEntries.last?.summary, "Upright Vertical")
        model.undo()
        XCTAssertEqual(model.editState.verticalPerspective, 0)
        XCTAssertEqual(model.editState.horizontalPerspective, 0.4, "one undo restores the whole correction")
    }

    func testLevelLeavesPerspectiveAlone() async throws {
        let model = try await makeModel()
        model.editState.verticalPerspective = 0.3
        model.editState.horizontalPerspective = 0.2
        let detector = gated(model, .lines(Self.levelLines(ccwTilt: -2)))
        let work = try XCTUnwrap(model.autoUpright(.level))
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 2)
        XCTAssertEqual(model.editState.verticalPerspective, 0.3)
        XCTAssertEqual(model.editState.horizontalPerspective, 0.2)
    }

    func testRepeatPressSolvingToTheSameValuesSaysSoAndAddsNoStep() async throws {
        let model = try await makeModel()
        let detector = gated(model, .lines(Self.levelLines(ccwTilt: 4)))
        let first = try XCTUnwrap(model.autoUpright(.level))
        detector.release()
        await first.value
        XCTAssertEqual(model.editState.straightenAngle, -4)
        let entries = model.historyEntries.count
        let second = try XCTUnwrap(model.autoUpright(.level))
        detector.release()
        await second.value
        XCTAssertEqual(model.editState.straightenAngle, -4, "not doubled")
        XCTAssertEqual(model.historyEntries.count, entries)
        XCTAssertEqual(model.uprightMessage, UprightMessages.alreadyApplied)
    }

    func testAlreadyUprightResetsAHandSetAngleAsOneStepAndOtherwiseOnlyExplains() async throws {
        let model = try await makeModel()
        model.editState.straightenAngle = 7
        let detector = gated(model, .lines(Self.levelLines(ccwTilt: 0.05)))
        var work = try XCTUnwrap(model.autoUpright(.level))
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.historyEntries.last?.summary, "Upright Level")
        XCTAssertNil(model.uprightMessage)
        let entries = model.historyEntries.count
        work = try XCTUnwrap(model.autoUpright(.level))
        detector.release()
        await work.value
        XCTAssertEqual(model.uprightMessage, UprightMessages.alreadyUpright)
        XCTAssertEqual(model.historyEntries.count, entries)
    }

    func testNoLinesAndFailureOnlyExplain() async throws {
        let model = try await makeModel()
        let entries = model.historyEntries.count
        let detector = gated(model, .lines(UprightLineDetector.Lines(width: 48, height: 32, vertical: [], horizontal: [])))
        var work = try XCTUnwrap(model.autoUpright(.vertical))
        detector.release()
        await work.value
        XCTAssertEqual(model.uprightMessage, UprightMessages.noLines)
        detector.result = .failed("boom")
        work = try XCTUnwrap(model.autoUpright(.level))
        detector.release()
        await work.value
        XCTAssertEqual(model.uprightMessage, "boom")
        XCTAssertEqual(model.historyEntries.count, entries)
    }

    func testEachRefusalShowsItsOwnMessage() async throws {
        let model = try await makeModel()
        func lines(_ specs: [(Double, Double)]) -> UprightLineDetector.Lines {
            let v = specs.map { spec -> UprightLineDetector.Line in
                let t = spec.1 * .pi / 180
                return UprightLineDetector.Line(theta: t, rho: spec.0 * cos(t), span: 30, votes: 100)
            }
            return UprightLineDetector.Lines(width: 48, height: 32, vertical: v, horizontal: [])
        }
        let detector = gated(model, .lines(lines([(-15, 0), (-5, 25), (5, -20), (15, 10)]))) // no common vanishing point
        var work = try XCTUnwrap(model.autoUpright(.vertical))
        detector.release()
        await work.value
        XCTAssertEqual(model.uprightMessage, UprightMessages.noAgreement)
        detector.result = .lines(lines([(0, 0), (2, 0)])) // bunched: too close to measure
        work = try XCTUnwrap(model.autoUpright(.vertical))
        detector.release()
        await work.value
        XCTAssertEqual(model.uprightMessage, UprightMessages.unmeasurable)
    }

    // MARK: Mutual exclusion with Auto Straighten

    private final class GatedHorizon: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        func detect(_ image: CIImage) -> HorizonDetector.Result { gate.wait(); return .angle(0) }
        func release() { gate.signal() }
    }

    func testUprightRefusesWhileAutoStraightenRuns() async throws {
        let model = try await makeModel()
        let horizon = GatedHorizon()
        model.horizonDetector = { horizon.detect($0) }
        let auto = try XCTUnwrap(model.autoStraighten())
        XCTAssertNil(model.autoUpright(.level), "Upright must not start while Auto Straighten is measuring")
        horizon.release()
        await auto.value
        model.uprightDetector = { _ in .failed("stub") }
        let again = try XCTUnwrap(model.autoUpright(.level), "and is available again afterwards")
        await again.value
    }

    func testAutoStraightenRefusesWhileUprightRuns() async throws {
        let model = try await makeModel()
        let detector = gated(model, .lines(Self.levelLines(ccwTilt: 4)))
        let upright = try XCTUnwrap(model.autoUpright(.level))
        XCTAssertNil(model.autoStraighten(), "Auto Straighten must not start while Upright is measuring")
        detector.release()
        await upright.value
    }

    // MARK: Real detector, end to end

    /// A distorted building with flip and Stretch already set still solves from the SOURCE, not the flipped picture.
    func testRealDetectionIgnoresFlipAndStretch() async throws {
        var tilt = EditState(); tilt.straightenAngle = 6
        let tilted = try UprightRoundTripTests.rendered(tilt, from: UprightRoundTripTests.building())
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: try writePNG(tilted, name: "tilted.png"))
        model.editState.flipHorizontal = true
        model.editState.transformAspect = 1
        let work = try XCTUnwrap(model.autoUpright(.level))
        await work.value
        XCTAssertNil(model.uprightMessage)
        XCTAssertEqual(model.editState.straightenAngle, -6, accuracy: 0.3)
        XCTAssertEqual(model.historyEntries.last?.summary, "Upright Level")
    }
}
