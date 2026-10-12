import CoreImage
import XCTest
@testable import PhotoApp

/// Per-mask Whites and Blacks: Blacks drives the same curve control point as the global Black Point; Whites moves the curve's
/// white end (no global counterpart).
final class MaskWhitesBlacksTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])

    private func solid(_ v: Double, size: Int = 400) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func red(_ image: CIImage) -> Float {
        var b = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: 200, y: 200, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return b[0]
    }

    private func covering(blacks: Double = 0, whites: Double = 0, kind: MaskKind = .radial) -> Mask {
        var m = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, rotationDegrees: 0, feather: 0.5)
        m.blacks = blacks; m.whites = whites
        return m
    }

    private func masked(_ v: Double, blacks: Double = 0, whites: Double = 0) -> Float {
        red(EditPipeline.apply(EditState(masks: [covering(blacks: blacks, whites: whites)]), to: solid(v)))
    }

    // MARK: Blacks == the global Black Point

    func testBlacksMatchesTheGlobalBlackPointAcrossTonesAndSigns() {
        for blacks in [-1.0, -0.5, 0.4, 1.0] {
            for v in [0.02, 0.1, 0.3, 0.7] {
                let global = red(EditPipeline.apply(EditState(blackPoint: blacks), to: solid(v)))
                XCTAssertEqual(masked(v, blacks: blacks), global, accuracy: 0.002, "blacks \(blacks) at linear \(v)")
            }
        }
        XCTAssertGreaterThan(abs(masked(0.1, blacks: -1) - 0.1), 0.02, "sanity: a real effect happened (negative blacks clip)")
        XCTAssertGreaterThan(abs(masked(0.02, blacks: 1) - 0.02), 0.0015, "and positive blacks lift the floor")
    }

    // MARK: Whites

    func testWhitesMoveTheBrightEndAndLeaveMidtonesAlone() {
        XCTAssertGreaterThan(masked(0.95, whites: 1), 1.0, "positive whites push a near-white into headroom")
        XCTAssertLessThan(masked(0.95, whites: -1), 0.8, "negative whites pull the white point down")
        // Linear 0.05 and 0.214 are perceptual 0.25 and 0.5 (measured to move by 0.007 or less in the spline's own space).
        for v in [0.05, 0.214] {
            XCTAssertEqual(masked(v, whites: 1), masked(v), accuracy: 0.01, "shadow/midtone \(v) barely moves at +1")
            XCTAssertEqual(masked(v, whites: -1), masked(v), accuracy: 0.01)
        }
        // Linear 0.5 (perceptual 0.735, next to the top anchor) DOES follow the white end: a bright tone, not a midtone.
        XCTAssertGreaterThan(masked(0.5, whites: 1), 0.55)
        XCTAssertLessThan(masked(0.5, whites: -1), 0.45)
    }

    func testTheWhiteEndLandsOnTheMeasuredSplineValues() {
        // Measured on the spline in perceptual space: white 1.0 -> 1.243 (+1) / 0.787 (-1) at span 0.10, i.e. linear 1.644 and
        // 0.582 after the pipeline's decode. A different span moves these (0.15 would give 0.692 perceptual).
        XCTAssertEqual(masked(1.0, whites: 1), 1.644, accuracy: 0.03)
        XCTAssertEqual(masked(1.0, whites: -1), 0.582, accuracy: 0.02)
    }

    func testWhitesAreMonotonicInTheSlider() {
        var last = -Float.infinity
        for w in stride(from: -1.0, through: 1.0, by: 0.25) {
            let out = masked(0.9, whites: w)
            XCTAssertGreaterThan(out, last, "whites \(w)")
            last = out
        }
    }

    // MARK: Identity, clamping, safety

    func testZeroWhitesAndBlacksIsAnExactNoOpMask() {
        let plain = red(EditPipeline.apply(EditState(), to: solid(0.6)))
        XCTAssertEqual(masked(0.6), plain, accuracy: 0.0001)
        XCTAssertTrue(covering().isIdentity)
        XCTAssertFalse(covering(whites: 0.1).isIdentity)
        XCTAssertFalse(covering(blacks: -0.1).isIdentity)
    }

    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(masked(0.9, whites: 40), masked(0.9, whites: 1), accuracy: 1e-5)
        XCTAssertEqual(masked(0.05, blacks: -40), masked(0.05, blacks: -1), accuracy: 1e-5)
    }

    /// The reviewer-found bug: Highlights +1 with Whites -1 in ONE curve reversed the brightest tones (brighter input, darker
    /// output) and sent extreme headroom negative. Whites is now its own curve, so the stage stays monotone.
    func testWorstCaseCombinationsStayMonotoneAndNonNegativeIncludingHeadroom() {
        let combos: [(shadows: Double, highlights: Double, blacks: Double, whites: Double)] = [
            (0, 1, 0, -1), (0, 1, 0, -0.5), (0, 1, 1, -1), (-1, -1, 1, 1), (0, 0.6, 0, -1), (-1, 1, -1, -1)
        ]
        // NOT included: Shadows +1 with Highlights +1 in one curve. That pair has a slightly negative end slope even with no
        // Whites at all (the GLOBAL path has it too: -0.029), a pre-existing limit of the parametric curve logged in
        // IMPROVEMENTS D64; Whites only scales it.
        let inputs: [Double] = [0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.0, 1.5, 2.0, 4.0, 16.0]
        for c in combos {
            var m = covering(blacks: c.blacks, whites: c.whites)
            m.shadows = c.shadows; m.highlights = c.highlights
            var last = -Float.infinity
            for v in inputs {
                let out = red(EditPipeline.apply(EditState(masks: [m]), to: solid(v)))
                XCTAssertTrue(out.isFinite && out >= 0, "\(c) at \(v): \(out)")
                XCTAssertGreaterThanOrEqual(out, last - 0.0005, "\(c): brighter input must not give a darker output (at \(v))")
                last = out
            }
        }
    }

    func testHeadroomAndAlphaSurvive() {
        let out = EditPipeline.apply(EditState(masks: [covering(whites: 1)]), to: solid(1.4))
        XCTAssertGreaterThan(red(out), 1.4, "headroom above 1.0 survives (and whites lift it)")
    }

    // MARK: A second mask kind uses the same path

    func testALinearMaskUsesTheSameWhitesPath() {
        var linear = Mask(kind: .linear, centerX: 0.5, centerY: 0.5, radiusX: 0, radiusY: 0, rotationDegrees: 0, feather: 0.5)
        linear.whites = -1
        linear.width = 4.0   // wide enough that the whole frame is inside the fully opaque side
        let out = red(EditPipeline.apply(EditState(masks: [linear]), to: solid(0.95)))
        XCTAssertLessThan(out, 0.95, "a linear mask also pulls whites down")
    }

    // MARK: Persistence

    func testCodableRoundTripAndMissingKeysAndFallbackIDStability() throws {
        var m = covering(blacks: -0.3, whites: 0.6)
        m.exposureEV = 0.25
        let back = try JSONDecoder().decode(Mask.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.blacks, -0.3)
        XCTAssertEqual(back.whites, 0.6)
        let old = try JSONDecoder().decode(Mask.self, from: Data(#"{"kind":"radial","centerX":0.5,"centerY":0.5,"radiusX":0.2,"radiusY":0.2,"exposureEV":1}"#.utf8))
        XCTAssertEqual(old.blacks, 0)
        XCTAssertEqual(old.whites, 0)
        XCTAssertFalse(old.isIdentity)
        // An id-less mask that does not use the new fields keeps the id it always had; using them gives a different one.
        let json = #"{"kind":"radial","centerX":0.5,"centerY":0.5,"radiusX":0.2,"radiusY":0.2,"exposureEV":1}"#
        let withWhites = #"{"kind":"radial","centerX":0.5,"centerY":0.5,"radiusX":0.2,"radiusY":0.2,"exposureEV":1,"whites":0.5}"#
        let idA = try JSONDecoder().decode(Mask.self, from: Data(json.utf8)).id
        let idB = try JSONDecoder().decode(Mask.self, from: Data(json.utf8)).id
        let idC = try JSONDecoder().decode(Mask.self, from: Data(withWhites.utf8)).id
        XCTAssertEqual(idA, idB, "deterministic")
        // PINNED: the fallback id this mask got before Whites/Blacks existed (the hash adds the two fields only when used).
        XCTAssertEqual(idA.uuidString, "DCE2D4FB-A6C1-45DF-AB1C-24E6E723A73D")
        XCTAssertNotEqual(idA, idC)
    }
}
