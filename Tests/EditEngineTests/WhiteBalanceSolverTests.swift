import XCTest
import CoreImage
@testable import PhotoApp

/// `WhiteBalanceSolver` is pure, deterministic computation — no UI
/// dependency — so it's fully testable without any rendering harness beyond
/// what the solver itself already does internally. All values below are
/// measured against the real solver (a real compiled probe run before this
/// file was written), not hand-derived — this class of problem (find the
/// input that produces a desired filter output) has no closed-form check to
/// derive against.
final class WhiteBalanceSolverTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf
    ])

    private func pixel(of image: CIImage) -> (r: Float, g: Float, b: Float) {
        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &buffer, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: linearSpace
        )
        return (buffer[0], buffer[1], buffer[2])
    }

    func testNeutralSampleReturnsIdentity() {
        let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: (0.18, 0.18, 0.18))
        XCTAssertEqual(outcome, .solved(temperature: 6500, tint: 0))
    }

    func testWarmCastConvergesLowerTemperature() {
        // A strong orange cast is too strong to fully correct within the
        // UI's own range — MEASURED: the search's best candidate sits at
        // the LOW edge of temperatureRange (a real, not-fully-neutral
        // residual remains), so this is classified solvedPartially, not
        // solved. Still converges in the CORRECT direction (well below the
        // 6500 identity).
        let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: (0.30, 0.18, 0.10))
        guard case .solvedPartially(let temperature, let tint) = outcome else {
            return XCTFail("expected solvedPartially, got \(outcome)")
        }
        XCTAssertEqual(temperature, 3500, accuracy: 1)
        XCTAssertEqual(tint, -50, accuracy: 1)
        XCTAssertLessThan(temperature, 6500)
    }

    func testCoolCastConvergesHigherTemperature() {
        let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: (0.10, 0.18, 0.30))
        guard case .solved(let temperature, let tint) = outcome else {
            return XCTFail("expected solved, got \(outcome)")
        }
        XCTAssertEqual(temperature, 9250, accuracy: 1)
        XCTAssertEqual(tint, 20, accuracy: 1)
        XCTAssertGreaterThan(temperature, 6500)
    }

    func testGreenCastConvergesPositiveTint() {
        let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: (0.15, 0.25, 0.15))
        guard case .solved(let temperature, let tint) = outcome else {
            return XCTFail("expected solved, got \(outcome)")
        }
        XCTAssertEqual(temperature, 5500, accuracy: 1)
        XCTAssertEqual(tint, 80, accuracy: 1)
        XCTAssertGreaterThan(tint, 0)
    }

    func testMagentaCastConvergesNegativeTint() {
        // Like the warm cast, a strong magenta cast hits the tint
        // boundary (-100) without fully neutralizing — solvedPartially.
        let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: (0.25, 0.12, 0.22))
        guard case .solvedPartially(let temperature, let tint) = outcome else {
            return XCTFail("expected solvedPartially, got \(outcome)")
        }
        XCTAssertEqual(temperature, 6000, accuracy: 1)
        XCTAssertEqual(tint, -100, accuracy: 1)
        XCTAssertLessThan(tint, 0)
    }

    func testSolvedParametersActuallyNeutralizeSample() {
        // The real correctness proof: feed the solved params back through
        // the REAL pipeline filter on the ORIGINAL sample and confirm it's
        // actually near-neutral, not just plausible-direction.
        let sample = (r: 0.22, g: 0.19, b: 0.15) // mild-warm, a clean `.solved` case
        guard case .solved(let temperature, let tint) = WhiteBalanceSolver.solve(sampleLinearRGB: sample) else {
            return XCTFail("expected a solved outcome for a mild cast")
        }

        let color = CIColor(red: sample.r, green: sample.g, blue: sample.b, alpha: 1, colorSpace: linearSpace)!
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let corrected = EditPipeline.whiteBalanced(input, temperature: temperature, tint: tint)
        let p = pixel(of: corrected)

        XCTAssertEqual(p.r, p.g, accuracy: 0.005)
        XCTAssertEqual(p.g, p.b, accuracy: 0.005)
    }

    func testScaleInvariance() {
        // MEASURED consequence of two already-established facts: WB is a
        // linear transform (EditPipeline's own doc comment) and the
        // solver's error metric normalizes by the transformed pixel's own
        // brightness — together these make the search's result depend only
        // on the sample's chromaticity RATIOS, not its absolute brightness.
        // Provably exact (not just approximately equal), so this asserts
        // exact equality, not a tolerance.
        let full = WhiteBalanceSolver.solve(sampleLinearRGB: (0.30, 0.18, 0.10))
        let half = WhiteBalanceSolver.solve(sampleLinearRGB: (0.15, 0.09, 0.05))
        XCTAssertEqual(full, half)
    }

    func testTooDarkSampleRejected() {
        let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: (0.005, 0.004, 0.006))
        XCTAssertEqual(outcome, .rejectedTooDark)
    }

    func testResultAlwaysWithinUIBounds() {
        let samples: [(Double, Double, Double)] = [
            (0.30, 0.18, 0.10), (0.10, 0.18, 0.30), (0.15, 0.25, 0.15), (0.25, 0.12, 0.22)
        ]
        for sample in samples {
            let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: sample)
            switch outcome {
            case .solved(let temperature, let tint), .solvedPartially(let temperature, let tint):
                XCTAssertTrue(WhiteBalanceSolver.temperatureRange.contains(temperature), "sample \(sample)")
                XCTAssertTrue(WhiteBalanceSolver.tintRange.contains(tint), "sample \(sample)")
            case .rejectedTooDark:
                XCTFail("sample \(sample) should not be rejected as too dark")
            }
        }
    }

    func testDeterministic() {
        let a = WhiteBalanceSolver.solve(sampleLinearRGB: (0.25, 0.15, 0.30))
        let b = WhiteBalanceSolver.solve(sampleLinearRGB: (0.25, 0.15, 0.30))
        XCTAssertEqual(a, b)
    }
}
