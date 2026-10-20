import CoreImage
import XCTest
@testable import PhotoApp

/// `ImageDocumentModel.autoStraighten()` through its `horizonDetector` seam, on small temp PNGs
/// (never a real folder: the sidecar folder-access prompt is declined).
@MainActor
final class AutoStraightenModelTests: XCTestCase {
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
        var result: HorizonDetector.Result = .angle(0)
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var extents: [CGRect] { lock.lock(); defer { lock.unlock() }; return _extents }
        func detect(_ image: CIImage) -> HorizonDetector.Result {
            lock.lock(); _calls += 1; _extents.append(image.extent); let r = result; lock.unlock()
            gate.wait()
            return r
        }
        func release() { gate.signal() }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AutoStraightenModelTests-\(UUID().uuidString)")
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

    private func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }

    func testAutoStraightenWithoutAnImageDoesNothingButExplain() {
        let model = ImageDocumentModel()
        XCTAssertNil(model.autoStraighten())
        XCTAssertFalse(model.isAutoStraightening)
        XCTAssertNotNil(model.straightenMessage)
        XCTAssertTrue(model.historyEntries.isEmpty)
    }

    func testDoubleClickRunsTheDetectorOnce() async throws {
        let model = try await makeModel()
        let detector = GatedDetector()
        detector.result = .angle(rad(4))
        model.horizonDetector = { detector.detect($0) }
        let first = try XCTUnwrap(model.autoStraighten())
        XCTAssertTrue(model.isAutoStraightening)
        XCTAssertNil(model.autoStraighten(), "a second press while running must be ignored")
        detector.release()
        await first.value
        XCTAssertEqual(detector.calls, 1)
        XCTAssertFalse(model.isAutoStraightening)
    }

    func testResultForAPhotoThatWasSwitchedAwayFromIsDropped() async throws {
        let model = try await makeModel()
        let detector = GatedDetector()
        detector.result = .angle(rad(4))
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        let other = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        await model.load(from: try writePNG(other, name: "b.png")) // bumps analysisGeneration
        let entries = model.historyEntries.count
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.historyEntries.count, entries)
        XCTAssertNil(model.straightenMessage)
    }

    func testResultArrivingWhileAnotherLoadIsInFlightIsDropped() async throws {
        let model = try await makeModel()
        let detector = GatedDetector()
        detector.result = .angle(rad(4))
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        let url = dir.appendingPathComponent("a.png")
        let load = Task { @MainActor in await model.load(from: url) }
        var spins = 0
        while !model.isLoadInFlight && spins < 1000 { await Task.yield(); spins += 1 }
        XCTAssertTrue(model.isLoadInFlight, "the load must be mid-flight when the result lands")
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertNil(model.straightenMessage)
        await load.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
    }

    func testSliderEditDuringDetectionSurvivesAndTheResultIsOneUndoStep() async throws {
        let model = try await makeModel()
        let detector = GatedDetector()
        detector.result = .angle(rad(-4))
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        model.editState.exposureEV = 0.5 // a burst still inside its coalescing window
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.exposureEV, 0.5)
        XCTAssertEqual(model.editState.straightenAngle, -4)
        XCTAssertEqual(model.historyEntries.last?.summary, "Auto Straighten")
        XCTAssertEqual(model.historyEntries.dropLast().last?.summary.contains("Exposure"), true,
                       "the exposure burst is its own entry; Auto Straighten is exactly one more")
        model.undo()
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.editState.exposureEV, 0.5)
    }

    func testDetectorReceivesTheUneditedSourceEvenWithGeometrySet() async throws {
        let model = try await makeModel(width: 48, height: 32)
        model.editState.flipHorizontal = true
        model.editState.transformAspect = 1
        model.editState.straightenAngle = 10 // would grow the extent if the pipeline were applied
        model.editState.cropInsetLeft = 0.25
        let detector = GatedDetector()
        detector.result = .none
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await work.value
        XCTAssertEqual(detector.extents, [CGRect(x: 0, y: 0, width: 48, height: 32)])
    }

    func testAlreadyLevelResetsAHandSetAngleAsOneStep() async throws {
        let model = try await makeModel()
        model.editState.straightenAngle = 7
        let detector = GatedDetector()
        detector.result = .angle(rad(0.05)) // measured on the uncorrected source: level
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await work.value
        XCTAssertEqual(model.editState.straightenAngle, 0)
        XCTAssertEqual(model.historyEntries.last?.summary, "Auto Straighten")
        XCTAssertNil(model.straightenMessage)
    }

    func testAlreadyLevelWithAngleZeroOnlyExplains() async throws {
        let model = try await makeModel()
        let entries = model.historyEntries.count
        let detector = GatedDetector()
        detector.result = .angle(rad(0.05))
        model.horizonDetector = { detector.detect($0) }
        let work = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await work.value
        XCTAssertEqual(model.straightenMessage, StraightenMessages.alreadyLevel)
        XCTAssertEqual(model.historyEntries.count, entries)
    }

    func testRepeatPressSolvingToTheSameAngleSaysSoAndAddsNoStep() async throws {
        let model = try await makeModel()
        let detector = GatedDetector()
        detector.result = .angle(rad(-4))
        model.horizonDetector = { detector.detect($0) }
        let first = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await first.value
        XCTAssertEqual(model.editState.straightenAngle, -4)
        let entries = model.historyEntries.count
        let second = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await second.value
        XCTAssertEqual(model.editState.straightenAngle, -4, "not doubled")
        XCTAssertEqual(model.historyEntries.count, entries)
        XCTAssertEqual(model.straightenMessage, StraightenMessages.alreadyApplied)
    }

    func testNoHorizonAndFailureOnlyExplain() async throws {
        let model = try await makeModel()
        let entries = model.historyEntries.count
        let detector = GatedDetector()
        model.horizonDetector = { detector.detect($0) }
        detector.result = .none
        var work = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await work.value
        XCTAssertEqual(model.straightenMessage, StraightenMessages.noHorizon)
        detector.result = .failed("boom")
        work = try XCTUnwrap(model.autoStraighten())
        detector.release()
        await work.value
        XCTAssertEqual(model.straightenMessage, "boom")
        XCTAssertEqual(model.historyEntries.count, entries)
    }

    func testPhotoSwitchClearsALateMessage() async throws {
        let model = try await makeModel()
        model.straightenMessage = "stale"
        let other = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        await model.load(from: try writePNG(other, name: "c.png"))
        XCTAssertNil(model.straightenMessage)
    }

    // MARK: Real Vision, end to end

    /// A tilted landscape with flip and Stretch already set still solves to the tilt's inverse: the measurement
    /// is taken on the source, not on the flipped / stretched picture (which would give -2t and 2.56x slopes).
    func testRealDetectionIgnoresFlipAndStretch() async throws {
        let tilted = try HorizonDetectorTests.rotated(6)
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: try writePNG(tilted, name: "tilted.png"))
        model.editState.flipHorizontal = true
        model.editState.transformAspect = 1
        let work = try XCTUnwrap(model.autoStraighten())
        await work.value
        // Skip ONLY for a genuine "Vision found nothing" outcome; "already level" would be a regression.
        if model.straightenMessage == StraightenMessages.noHorizon { throw XCTSkip("Vision found no horizon") }
        XCTAssertNil(model.straightenMessage)
        XCTAssertEqual(model.editState.straightenAngle, -6, accuracy: 0.25)
        XCTAssertEqual(model.historyEntries.last?.summary, "Auto Straighten")
    }
}
