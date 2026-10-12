import CoreImage
import XCTest
@testable import PhotoApp

final class VignetteSoftnessTests: XCTestCase {
    // MARK: Mapping

    func testZeroIsTheExactOriginalFalloff() {
        XCTAssertEqual(VignetteMath.falloff(softness: 0).bitPattern, 0.5.bitPattern)
        XCTAssertEqual(VignetteMath.falloff(softness: -0.0).bitPattern, 0.5.bitPattern)
    }

    func testEndsAndLinearity() {
        XCTAssertEqual(VignetteMath.falloff(softness: -1), 0.1, accuracy: 1e-12)
        XCTAssertEqual(VignetteMath.falloff(softness: 1), 0.6, accuracy: 1e-12)
        XCTAssertEqual(VignetteMath.falloff(softness: -0.5), 0.3, accuracy: 1e-12)
        XCTAssertEqual(VignetteMath.falloff(softness: 0.5), 0.55, accuracy: 1e-12)
        var last = -1.0
        for s in stride(from: -1.0, through: 1.0, by: 0.1) {
            let f = VignetteMath.falloff(softness: s)
            XCTAssertGreaterThan(f, last, "monotonic at \(s)")
            last = f
        }
    }

    func testOutOfRangeAndNonFiniteInput() {
        XCTAssertEqual(VignetteMath.falloff(softness: 9), 0.6, accuracy: 1e-12)
        XCTAssertEqual(VignetteMath.falloff(softness: -9), 0.1, accuracy: 1e-12)
        XCTAssertEqual(VignetteMath.falloff(softness: .nan), 0.5)
        XCTAssertEqual(VignetteMath.falloff(softness: .infinity), 0.5)
    }

    // MARK: Rendering (solid 0.5 field, 400x300, linear light — the measurement setup)

    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])

    private func probe(_ state: EditState) -> (centre: Float, quarter: Float, edge: Float, corner: Float) {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let out = EditPipeline.apply(state, to: base)
        func px(_ x: Double, _ y: Double) -> Float {
            var b = [Float](repeating: 0, count: 4)
            context.render(out, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: space)
            return b[0]
        }
        return (px(200, 150), px(300, 225), px(395, 150), px(2, 2))
    }

    private func vignette(radius: Double, softness: Double, strength: Double = 1) -> EditState {
        var s = EditState()
        s.vignetteStrength = strength; s.vignetteRadius = radius; s.vignetteSoftness = softness
        return s
    }

    func testDefaultRenderMatchesTheMeasuredOriginal() {
        // Recorded in the spike at falloff 0.5, radius slider 0 and 1.
        let tight = probe(vignette(radius: 0, softness: 0))
        XCTAssertEqual(tight.quarter, 0.26163286, accuracy: 0.002)
        XCTAssertEqual(tight.corner, 0.010663303, accuracy: 0.002)
        let wide = probe(vignette(radius: 1, softness: 0))
        XCTAssertEqual(wide.quarter, 0.44186813, accuracy: 0.002)
        XCTAssertEqual(wide.edge, 0.33332455, accuracy: 0.002)
    }

    func testSofterReachesFurtherInAndHarderStaysNearTheEdge() {
        for radius in [0.0, 1.0] {
            let hard = probe(vignette(radius: radius, softness: -1))
            let mid = probe(vignette(radius: radius, softness: 0))
            let soft = probe(vignette(radius: radius, softness: 1))
            XCTAssertGreaterThan(hard.quarter, mid.quarter + 0.01, "hard keeps the quarter point brighter (radius \(radius))")
            XCTAssertGreaterThan(mid.quarter, soft.quarter + 0.005, "soft darkens the quarter point more (radius \(radius))")
            // The edge midpoint's order depends on the radius (measured): at the wide radius a harder falloff leaves the
            // edge brighter; at the tight radius the vignette is already past that point and the order inverts.
            if radius == 1 {
                XCTAssertGreaterThan(hard.edge, mid.edge)
                XCTAssertGreaterThan(mid.edge, soft.edge)
            } else {
                XCTAssertLessThan(hard.edge, mid.edge)
                XCTAssertLessThan(mid.edge, soft.edge)
            }
        }
    }

    func testTheCentreStaysPristineAtBothEnds() {
        for radius in [0.0, 0.5, 1.0] {
            for softness in [-1.0, 0, 1.0] {
                XCTAssertEqual(probe(vignette(radius: radius, softness: softness)).centre, 0.4998, accuracy: 0.002,
                               "centre untouched (radius \(radius), softness \(softness))")
            }
        }
    }

    func testSoftnessAloneDoesNothingAndNegativeStrengthStillLightens() {
        let none = probe(vignette(radius: 0.5, softness: 1, strength: 0))
        XCTAssertEqual(none.corner, 0.5, accuracy: 0.0005)
        XCTAssertEqual(none.quarter, 0.5, accuracy: 0.0005)
        let light = probe(vignette(radius: 0.5, softness: 1, strength: -1))
        XCTAssertGreaterThan(light.corner, 0.5)
    }

    func testHardEndStillCarriesARealVignetteAtTheWideRadius() {
        // Measured: at the WIDE radius falloff 0.0 leaves the mid-edge at 0.4897 (the gradient collapsed to the extreme
        // corners), 0.4597 at falloff 0.1 and 0.3333 at 0.5. The hard end must stay clearly short of that collapse.
        let hard = probe(vignette(radius: 1, softness: -1))
        XCTAssertEqual(hard.edge, 0.4597, accuracy: 0.003)
        XCTAssertLessThan(hard.edge, 0.475)
    }
}
