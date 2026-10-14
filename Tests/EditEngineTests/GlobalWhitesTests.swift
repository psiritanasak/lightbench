import CoreImage
import XCTest
@testable import PhotoApp

/// The global Whites slider: the same white-end pass the per-mask Whites runs, applied to the whole image.
final class GlobalWhitesTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])

    private func solid(_ v: Double) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    private func red(_ image: CIImage) -> Float {
        var b = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return b[0]
    }

    private func render(_ v: Double, whites: Double) -> Float {
        var state = EditState()
        state.whites = whites
        return red(EditPipeline.apply(state, to: solid(v)))
    }

    // MARK: Pipeline

    func testZeroWhitesIsAnExactNoOp() {
        for v in [0.0, 0.1, 0.5, 1.0, 2.5] {
            XCTAssertEqual(render(v, whites: 0), Float(v), accuracy: 0.0001, "linear \(v)")
        }
    }

    func testWhitesMoveTheBrightEndAndLeaveShadowsAndMidtonesAlone() {
        XCTAssertGreaterThan(render(0.95, whites: 1), 1.0)
        XCTAssertLessThan(render(0.95, whites: -1), 0.8)
        for v in [0.05, 0.214] {
            XCTAssertEqual(render(v, whites: 1), render(v, whites: 0), accuracy: 0.01, "\(v)")
            XCTAssertEqual(render(v, whites: -1), render(v, whites: 0), accuracy: 0.01, "\(v)")
        }
    }

    func testGlobalWhitesMatchPerMaskWhitesAtFullCoverage() {
        var mask = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, rotationDegrees: 0, feather: 0.5)
        for w in [-1.0, -0.4, 0.6, 1.0] {
            for v in [0.2, 0.7, 1.0] {
                mask.whites = w
                let masked = red(EditPipeline.apply(EditState(masks: [mask]), to: solid(v)))
                XCTAssertEqual(render(v, whites: w), masked, accuracy: 0.002, "whites \(w) at \(v)")
            }
        }
    }

    func testWhitesAreMonotonicInTheSliderAndInTheTone() {
        var last = -Float.infinity
        for w in stride(from: -1.0, through: 1.0, by: 0.25) {
            let out = render(0.9, whites: w)
            XCTAssertGreaterThan(out, last, "whites \(w)")
            last = out
        }
        for w in [-1.0, -0.5, 0.5, 1.0] {
            var previous = -Float.infinity
            for v in stride(from: 0.0, through: 4.0, by: 0.1) {
                let out = render(v, whites: w)
                XCTAssertGreaterThanOrEqual(out, previous - 0.0001, "whites \(w) at \(v)")
                previous = out
            }
        }
    }

    func testWhitesAreClampedAndStillMonotoneOutOfRange() {
        XCTAssertEqual(render(0.9, whites: 7), render(0.9, whites: 1), accuracy: 0.0001)
        XCTAssertEqual(render(0.9, whites: -7), render(0.9, whites: -1), accuracy: 0.0001)
    }

    func testWhitesWorkWhileEveryOtherToneControlIsAtIdentity() {
        // The perceptual block must switch on for Whites alone (the guard), not just when another slider is active.
        XCTAssertNotEqual(render(0.95, whites: 0.5), Float(0.95), accuracy: 0.001)
    }

    // MARK: State plumbing

    func testMissingKeyDecodesToZeroAndRoundTrips() throws {
        let decoded = try JSONDecoder().decode(EditState.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.whites, 0)
        var state = EditState()
        state.whites = -0.37
        let again = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(again.whites, -0.37)
    }

    func testPresetsCarryItCompareDropsItAndItCountsAsAnEdit() {
        var source = EditState()
        source.whites = 0.5
        XCTAssertEqual(source.applyingPreset(onto: EditState()).whites, 0.5)
        XCTAssertEqual(source.comparisonOriginal().whites, 0)
        XCTAssertFalse(source.isEffectivelyIdentity)
    }

    func testUIHasTheSliderAndResetClearsIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ui = try String(contentsOf: root.appendingPathComponent("Sources/UI/AdjustTabView.swift"), encoding: .utf8)
        XCTAssertTrue(ui.contains("label: \"Whites\", value: $document.editState.whites"))
        XCTAssertTrue(ui.contains("&& state.whites == 0"), "Reset Adjustments must see Whites as an edit")
        XCTAssertTrue(ui.contains("document.editState.whites = 0"), "Reset Adjustments must clear it")
    }

    func testHistoryNamesTheField() {
        var a = EditState(), b = EditState()
        b.whites = 0.3
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: a, to: b), ["whites"])
        a.whites = 0.3
        XCTAssertEqual(EditStateDiff.displayName(forField: "whites"), "Whites")
    }
}
