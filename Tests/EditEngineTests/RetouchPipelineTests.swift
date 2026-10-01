import CoreImage
import XCTest
@testable import PhotoApp

/// `EditPipeline.applyRetouch`: spot removal (clone / heal) in the source frame, first pipeline stage.
final class RetouchPipelineTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    // MARK: Helpers

    /// An image from `f(x, yUp) -> linear gray`; extent origin (0,0), y UP like Core Image.
    private func image(_ width: Int, _ height: Int, alpha: Float = 1, _ f: (Double, Double) -> Float) -> CIImage {
        var data = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let yUp = Double(height - 1 - row)
            for x in 0..<width {
                let v = f(Double(x), yUp)
                let i = (row * width + x) * 4
                data[i] = v * alpha; data[i + 1] = v * alpha; data[i + 2] = v * alpha; data[i + 3] = alpha
            }
        }
        return CIImage(bitmapData: Data(buffer: UnsafeBufferPointer(start: data, count: data.count)),
                       bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linearSpace)
    }

    private func value(_ image: CIImage, _ x: Int, _ yUp: Int) -> Float {
        var b = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: yUp, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        return b[0]
    }

    private func alphaValue(_ image: CIImage, _ x: Int, _ yUp: Int) -> Float {
        var b = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: yUp, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        return b[3]
    }

    private func pixels(_ image: CIImage, x: Int, y: Int, size: Int) -> [Float] {
        var b = [Float](repeating: 0, count: size * size * 4)
        context.render(image, toBitmap: &b, rowBytes: size * 16, bounds: CGRect(x: x, y: y, width: size, height: size), format: .RGBAf, colorSpace: linearSpace)
        return stride(from: 0, to: b.count, by: 4).map { b[$0] }
    }

    private func mean(_ image: CIImage, x: Int, y: Int, size: Int) -> (mean: Float, std: Float) {
        var b = [Float](repeating: 0, count: size * size * 4)
        context.render(image, toBitmap: &b, rowBytes: size * 16, bounds: CGRect(x: x, y: y, width: size, height: size), format: .RGBAf, colorSpace: linearSpace)
        let vs = stride(from: 0, to: b.count, by: 4).map { b[$0] }
        let m = vs.reduce(0, +) / Float(vs.count)
        return (m, (vs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(vs.count)).squareRoot())
    }

    private func spot(x: Double, y: Double, radius: Double, dx: Double, dy: Double = 0, mode: RetouchMode = .clone,
                      feather: Double = 0, opacity: Double = 1) -> RetouchSpot {
        var s = RetouchSpot()
        s.x = x; s.y = y; s.radius = radius; s.sourceDX = dx; s.sourceDY = dy
        s.mode = mode; s.feather = feather; s.opacity = opacity
        return s
    }

    private func state(_ spots: [RetouchSpot]) -> EditState { var s = EditState(); s.retouchSpots = spots; return s }

    private func render(_ s: EditState, _ input: CIImage) -> CIImage { EditPipeline.apply(s, to: input) }

    private let ramp = { (x: Double, _: Double) -> Float in Float(0.1 + 0.8 * x / 400) }

    // MARK: Clone

    func testCloneCopiesTheSourceInsideTheDiscAndLeavesTheRestAlone() {
        let input = image(400, 400, ramp)
        // R = 0.1 * 400 = 40 px; source 0.3 * 400 = 120 px to the right.
        let out = render(state([spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.3)]), input)
        XCTAssertEqual(value(out, 200, 200), Float(0.1 + 0.8 * 320 / 400), accuracy: 0.01, "centre = the source pixel")
        XCTAssertEqual(value(out, 220, 200), Float(0.1 + 0.8 * 340 / 400), accuracy: 0.01, "inside the disc too")
        XCTAssertEqual(value(out, 270, 200), value(input, 270, 200), accuracy: 0.002, "outside the disc: untouched")
        XCTAssertEqual(value(out, 20, 20), value(input, 20, 20), accuracy: 0.002, "far away: untouched")
    }

    func testOpacityBlendsLinearlyAndZeroIsAnExactNoOp() {
        let input = image(400, 400, ramp)
        let half = render(state([spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.3, opacity: 0.5)]), input)
        let expected = Float(0.1 + 0.8 * 200 / 400) * 0.5 + Float(0.1 + 0.8 * 320 / 400) * 0.5
        XCTAssertEqual(value(half, 200, 200), expected, accuracy: 0.01)
        let zero = render(state([spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.3, opacity: 0)]), input)
        XCTAssertEqual(value(zero, 200, 200), value(render(EditState(), input), 200, 200), "opacity 0 = no change at all")
    }

    func testNoSpotsIsTheUntouchedInputAndFarPixelsSurviveTheEncodeDecodeRoundTrip() {
        let input = image(400, 400, ramp)
        XCTAssertEqual(value(render(EditState(), input), 300, 100), value(input, 300, 100))
        let out = render(state([spot(x: 0.2, y: 0.5, radius: 0.05, dx: 0.2)]), input)
        XCTAssertEqual(value(out, 350, 50), value(input, 350, 50), accuracy: 2e-4)
    }

    func testFeatherSoftensTheEdgeOutwards() {
        let input = image(400, 400, ramp)
        // dx 0.2 (80 px): the source stays well inside the frame for both feathers (a wider feather needs a bigger
        // margin, which would otherwise clamp a far source and shift it by a few pixels).
        let hard = render(state([spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.2, feather: 0)]), input)
        let soft = render(state([spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.2, feather: 1)]), input)
        // R = 40; with feather 1 the soft edge reaches 1.6 R = 64. At d = 52: hard = untouched, soft = partly replaced.
        XCTAssertEqual(value(hard, 252, 200), value(input, 252, 200), accuracy: 0.002)
        XCTAssertGreaterThan(abs(value(soft, 252, 200) - value(input, 252, 200)), 0.02)
        XCTAssertEqual(value(soft, 200, 200), value(hard, 200, 200), accuracy: 0.002, "the core is unaffected by feather")
    }

    /// A spot whose centre and radius give a FRACTIONAL bounding box must not leave a seam: every pixel outside the
    /// feathered disc is unchanged (within the encode/decode round trip) and alpha stays 1 everywhere. (A reviewer
    /// reproduced alpha 0.70 on the box edge before the box was made whole-pixel.)
    func testFractionalBoundingBoxLeavesNoSeam() {
        let input = image(400, 400, ramp)
        var b = [Float](repeating: 0, count: 400 * 400 * 4), original = b
        context.render(input, toBitmap: &original, rowBytes: 400 * 16, bounds: CGRect(x: 0, y: 0, width: 400, height: 400), format: .RGBAf, colorSpace: linearSpace)
        // Several centres/radii: the edge coverage of a fractional box depends on the fractional parts. The last three
        // are frame-edge spots (their roi is clipped by the frame).
        for (fx, fy, r) in [(0.5123, 0.4877, 0.0233), (0.5361, 0.5249, 0.0171), (0.4419, 0.4663, 0.0297), (0.5712, 0.5538, 0.0129),
                              (0.021, 0.503, 0.0221), (0.4871, 0.983, 0.0187), (0.9741, 0.0153, 0.0143)] {
            for mode in [RetouchMode.clone, .heal] {
                let s = spot(x: fx, y: fy, radius: r, dx: 0.17, mode: mode, feather: 0.4)
                let out = render(state([s]), input)
                var maxOutside: Float = 0, minAlpha: Float = 1
                let cx = fx * 400, cy = fy * 400, feathered = r * 400 * (1 + 0.6 * 0.4)
                context.render(out, toBitmap: &b, rowBytes: 400 * 16, bounds: CGRect(x: 0, y: 0, width: 400, height: 400), format: .RGBAf, colorSpace: linearSpace)
                for row in 0..<400 { for x in 0..<400 {
                    let yUp = Double(399 - row)
                    let i = (row * 400 + x) * 4
                    minAlpha = min(minAlpha, b[i + 3])
                    if hypot(Double(x) + 0.5 - cx, yUp + 0.5 - cy) > feathered + 1.5 {
                        maxOutside = max(maxOutside, abs(b[i] - original[i]))
                    }
                } }
                XCTAssertEqual(minAlpha, 1, accuracy: 1e-5, "\(mode) at (\(fx), \(fy)): a seam would show as alpha < 1")
                XCTAssertLessThan(maxOutside, 5e-4, "\(mode) at (\(fx), \(fy)): nothing outside the feathered disc may change")
            }
        }
    }

    /// MEASURED live (screenshot pixels: a 1 px column ~3% darker at the left/right edge of every spot's box): the app
    /// renders the pipeline output DOWNSCALED to the view, and Core Image applies that scale to the merge kernel's
    /// inputs BEFORE the kernel runs — so the patch (transparent outside its box) is bilinearly mixed with transparent at
    /// its edge and the merge writes that partly transparent edge over the base. A full-resolution render never shows it
    /// (the earlier seam test passed), hence this test renders through a downscale.
    func testDownscaledRenderLeavesNoSeamAtTheBoxEdge() {
        let input = image(400, 400) { x, y in Float(0.3 + 0.2 * x / 400 + 0.1 * y / 400) }
        for mode in [RetouchMode.clone, .heal] {
            let s = spot(x: 0.5123, y: 0.4877, radius: 0.0233, dx: 0.17, mode: mode, feather: 0.4)
            let scale = 0.37
            func scaled(_ i: CIImage) -> CIImage { i.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            let with = scaled(render(state([s]), input)), without = scaled(render(EditState(), input))
            let w = 148, h = 148
            var a = [Float](repeating: 0, count: w * h * 4), b = a
            context.render(with, toBitmap: &a, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: linearSpace)
            context.render(without, toBitmap: &b, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: linearSpace)
            let cx = 0.5123 * 400 * scale, cy = 0.4877 * 400 * scale
            let feathered = 0.0233 * 400 * 1.24 * scale
            var worst: Float = 0
            for row in 0..<h { for x in 0..<w {
                let yUp = Double(h - 1 - row)
                if hypot(Double(x) + 0.5 - cx, yUp + 0.5 - cy) > feathered + 2.5 {
                    let i = (row * w + x) * 4
                    worst = max(worst, abs(a[i] - b[i]), abs(a[i + 3] - b[i + 3]))
                }
            } }
            XCTAssertLessThan(worst, 2e-3, "\(mode): a box-edge seam appears only in a downscaled render")
        }
    }

    // MARK: Heal

    /// Dest area (around x=100) is flat 0.2; the source area (around x=300) is 0.5 with a fine checker texture.
    private var toneMismatch: (CGFloat, CGFloat) -> Float { { x, y in
        let d = hypot(x - 300, y - 200)
        if d < 90 { return 0.5 + 0.1 * ((Int(x / 4) + Int(y / 4)) % 2 == 0 ? 1 : -1) }
        return 0.2
    } }

    func testHealMatchesTheSurroundingsToneWhileCloneCopiesTheSourceTone() {
        let input = image(400, 400) { x, y in self.toneMismatch(CGFloat(x), CGFloat(y)) }
        let target = spot(x: 0.25, y: 0.5, radius: 0.1, dx: 0.5)
        var healSpot = target; healSpot.mode = .heal
        let heal = mean(render(state([healSpot]), input), x: 80, y: 180, size: 40)
        let clone = mean(render(state([target]), input), x: 80, y: 180, size: 40)
        XCTAssertEqual(clone.mean, 0.5, accuracy: 0.03, "clone brings the source's tone")
        XCTAssertEqual(heal.mean, 0.2, accuracy: 0.04, "heal takes the destination's surroundings' tone")
        XCTAssertGreaterThan(heal.std, 0.02, "heal keeps the source's texture")
    }

    /// Dest area (x ~ 100) is a bright flat 0.8; the source area (x ~ 300) is a DARK 0.05 field with a +-0.03 checker.
    private var brightDestDarkSource: (CGFloat, CGFloat) -> Float { { x, y in
        hypot(x - 300, y - 200) < 90 ? 0.05 + 0.03 * ((Int(x / 4) + Int(y / 4)) % 2 == 0 ? 1 : -1) : 0.8
    } }

    /// The heal runs in the PERCEPTUAL domain (spike: pale halos in linear): the copied texture is carried across in
    /// perceptual units, so its linear swing is rescaled to the BRIGHT destination's sensitivity. A linear-domain
    /// heal would keep the source's +-0.03 swing (std ~0.03) — measured below as the discriminator.
    func testHealCarriesTextureInPerceptualUnits() {
        let input = image(400, 400) { x, y in self.brightDestDarkSource(CGFloat(x), CGFloat(y)) }
        var healSpot = spot(x: 0.25, y: 0.5, radius: 0.1, dx: 0.5); healSpot.mode = .heal
        let heal = mean(render(state([healSpot]), input), x: 80, y: 180, size: 40)
        print("RETOUCH-DOMAIN heal mean/std on bright dest, dark textured source:", heal.mean, heal.std)
        XCTAssertEqual(heal.mean, 0.8, accuracy: 0.06, "takes the destination's brightness")
        XCTAssertGreaterThan(heal.std, 0.06, "texture rescaled to the bright destination (a linear heal would be ~0.03)")
    }

    /// At thumbnail scale (R = 10 px) heal still takes the destination's tone (the pixel constants thin the ring only
    /// for much smaller radii — documented on `applyRetouch`).
    func testHealStillMatchesToneAtASmallProxyScale() {
        let input = image(100, 100) { x, y in self.toneMismatch(CGFloat(x * 4), CGFloat(y * 4)) }
        var healSpot = spot(x: 0.25, y: 0.5, radius: 0.1, dx: 0.5); healSpot.mode = .heal
        let heal = mean(render(state([healSpot]), input), x: 20, y: 45, size: 10)
        XCTAssertEqual(heal.mean, 0.2, accuracy: 0.07)
    }

    // MARK: Geometry / ordering

    func testProxyScaleGivesTheSameRepair() {
        func render(size: Int) -> Float {
            let input = image(size, size) { x, y in Float(0.1 + 0.6 * x / Double(size) + 0.2 * y / Double(size)) }
            let out = self.render(state([spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.3, feather: 0.5)]), input)
            return value(out, size / 2, size / 2)
        }
        XCTAssertEqual(render(size: 400), render(size: 100), accuracy: 0.03)
    }

    func testASourceOffTheFrameIsClampedInsteadOfSmeared() {
        let input = image(400, 400, ramp)
        // R = 20, feather 0.5 -> ringOut = 36, margin 38: a centre at 380 may borrow from no further right than 362.
        let out = render(state([spot(x: 0.95, y: 0.5, radius: 0.05, dx: 0.4, feather: 0.5)]), input)
        XCTAssertEqual(out.extent, input.extent)
        XCTAssertEqual(value(out, 380, 200), Float(0.1 + 0.8 * 362 / 400), accuracy: 0.01)
        XCTAssertTrue(value(out, 399, 399).isFinite)
    }

    func testASpotFollowsItsContentUnderFlip() {
        // A dark dot at (100, 200) on a flat 0.5 field; the spot removes it by cloning from 120 px above.
        let input = image(400, 400) { x, y in hypot(x - 100, y - 200) < 10 ? 0.02 : 0.5 }
        var s = state([spot(x: 0.25, y: 0.5, radius: 0.05, dx: 0, dy: 0.3)])
        s.flipHorizontal = true
        XCTAssertEqual(value(render(s, input), 300, 200), 0.5, accuracy: 0.01, "repaired where the dot now sits (mirrored)")
        var unrepaired = EditState(); unrepaired.flipHorizontal = true
        XCTAssertEqual(value(render(unrepaired, input), 300, 200), 0.02, accuracy: 0.01, "and it really was dark without the spot")
    }

    func testSpotsApplySequentiallyAndOrderMatters() {
        let input = image(400, 400) { x, y in
            (hypot(x - 100, y - 100) < 10 || hypot(x - 300, y - 100) < 10) ? 0.02 : 0.5
        }
        let fixA = spot(x: 0.25, y: 0.25, radius: 0.05, dx: 0, dy: 0.3)       // dot A repaired from above
        let copyAIntoB = spot(x: 0.75, y: 0.25, radius: 0.05, dx: -0.5)        // B's source is A's location
        XCTAssertEqual(value(render(state([fixA, copyAIntoB]), input), 300, 100), 0.5, accuracy: 0.02,
                       "A already repaired when B borrows from it")
        XCTAssertEqual(value(render(state([copyAIntoB, fixA]), input), 300, 100), 0.02, accuracy: 0.02,
                       "borrowing before A is repaired copies the defect — order matters")
    }

    /// MEASURED: heal-then-exposure vs exposure-then-heal differ by only ~0.0001 mean abs pixel on this scene (the
    /// heal makes the patch match its surroundings, so the result tracks the destination's tone either way). The
    /// stage order is therefore a CONVENTION (repair the unadjusted pixels so every later slider treats them like any
    /// others), not something this test can distinguish — it only pins that exposure composes with the repair.
    func testExposureComposesWithTheRepair() {
        let input = image(400, 400) { x, y in self.toneMismatch(CGFloat(x), CGFloat(y)) }
        var healSpot = spot(x: 0.25, y: 0.5, radius: 0.1, dx: 0.5); healSpot.mode = .heal
        var both = state([healSpot]); both.exposureEV = 1
        let pipeline = pixels(render(both, input), x: 80, y: 180, size: 40)
        let healThenExposure = pixels(render(EditState(exposureEV: 1), render(state([healSpot]), input)), x: 80, y: 180, size: 40)
        let exposureThenHeal = pixels(render(state([healSpot]), render(EditState(exposureEV: 1), input)), x: 80, y: 180, size: 40)
        func gap(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Float(a.count) }
        print("RETOUCH-ORDER-GAP mean abs pixel gap, heal-then-exposure vs exposure-then-heal:", gap(healThenExposure, exposureThenHeal))
        XCTAssertLessThan(gap(pipeline, healThenExposure), 0.002)
    }

    // MARK: Robustness / plumbing

    func testNonFiniteSpotsAreSkippedAndAlphaAndExtentSurvive() {
        let input = image(400, 400, alpha: 0.5, ramp)
        var bad = spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.3); bad.x = .nan
        let ok = spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.3)
        let out = render(state([bad, ok]), input)
        XCTAssertEqual(out.extent, input.extent)
        XCTAssertEqual(alphaValue(out, 200, 200), 0.5, accuracy: 1e-3)
        XCTAssertTrue(value(out, 200, 200).isFinite)
        XCTAssertEqual(value(render(state([bad]), input), 200, 200), value(render(EditState(), input), 200, 200), "a lone bad spot is a no-op")
    }

    func testComparisonOriginalRendersWithoutTheSpots() {
        let input = image(400, 400, ramp)
        let s = state([spot(x: 0.5, y: 0.5, radius: 0.1, dx: 0.3)])
        XCTAssertEqual(value(render(s.comparisonOriginal(), input), 200, 200), value(render(EditState(), input), 200, 200))
        XCTAssertNotEqual(value(render(s, input), 200, 200), value(render(EditState(), input), 200, 200))
    }

    func testSpotAtTheFrameEdgeAndTinyOrHugeRadiiDoNotCrash() {
        let input = image(200, 200, ramp)
        for r in [0.0, 0.002, 0.1, 5.0] {
            for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.5, 0.0)] {
                let out = render(state([spot(x: x, y: y, radius: r, dx: 0.3, feather: 1)]), input)
                XCTAssertTrue(value(out, 100, 100).isFinite, "r \(r) at (\(x), \(y))")
            }
        }
    }
}
