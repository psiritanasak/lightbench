import CoreImage
import XCTest
@testable import PhotoApp

/// B&W extras: Intensity (scales the Mix), Neutrals, Tone (one monotone grey curve) and Grain (through the Grain stage).
final class BWExtrasTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])

    private func solid(_ r: Double, _ g: Double, _ b: Double, a: Double = 1, size: Int = 1) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func pixel(_ image: CIImage, at p: Int = 0) -> (r: Float, g: Float, b: Float, a: Float) {
        var buffer = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &buffer, rowBytes: 16, bounds: CGRect(x: p, y: p, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    private func bw(_ configure: (inout EditState) -> Void = { _ in }) -> EditState {
        var s = EditState()
        s.blackAndWhite = true
        configure(&s)
        return s
    }

    private func grey(_ state: EditState, _ v: Double) -> Float { pixel(EditPipeline.apply(state, to: solid(v, v, v))).r }

    // MARK: identity and gating

    func testPlainBlackAndWhiteIsPinnedAndEveryExtraAtZeroLeavesItExactly() {
        let plain = pixel(EditPipeline.apply(bw(), to: solid(0.7, 0.3, 0.2)))
        // Pinned from a real run of the build where every extra is inactive (that path is the pre-extras one: the stage guards are false and the
        // Mix stop count is `kGrayMixStops * 1`); it fails if the plain B&W conversion ever drifts.
        XCTAssertEqual(plain.r, 0.35986814, accuracy: 0.0005)
        XCTAssertEqual(plain.r, plain.g, accuracy: 0.0001)
        let mixed = pixel(EditPipeline.apply(bw { $0.grayMixBlue = -0.5 }, to: solid(0.1, 0.2, 0.8)))
        let withZeroExtras = pixel(EditPipeline.apply(bw { $0.grayMixBlue = -0.5; $0.bwIntensity = 0; $0.bwNeutrals = 0; $0.bwTone = 0; $0.bwGrain = 0 },
                                                      to: solid(0.1, 0.2, 0.8)))
        XCTAssertEqual(mixed.r, withZeroExtras.r, "zero extras must not change an active Mix by even one ulp")
    }

    func testNothingHappensWhileBlackAndWhiteIsOff() {
        var s = EditState()
        s.bwIntensity = 1; s.bwNeutrals = 1; s.bwTone = 1; s.bwGrain = 1
        let out = pixel(EditPipeline.apply(s, to: solid(0.7, 0.3, 0.2)))
        XCTAssertEqual(out.r, 0.7, accuracy: 0.0005)
        XCTAssertEqual(out.g, 0.3, accuracy: 0.0005)
        XCTAssertEqual(EditPipeline.effectiveGrain(s), 0, "B&W grain is grain only while B&W is on")
        // Even when the perceptual block is entered for another reason (a saturation edit), the curve is gated on B&W itself.
        var saturated = s
        saturated.hslSaturation = 0.01
        let withOnlyDecoy = EditState(hslSaturation: 0.01)
        XCTAssertEqual(pixel(EditPipeline.apply(saturated, to: solid(0.7, 0.3, 0.2))).r, pixel(EditPipeline.apply(withOnlyDecoy, to: solid(0.7, 0.3, 0.2))).r, accuracy: 0.0001)
    }

    // MARK: Neutrals and Tone

    func testNeutralsLightenOrDarkenTheMidGreys() {
        let mid = grey(bw(), 0.2)
        XCTAssertGreaterThan(grey(bw { $0.bwNeutrals = 1 }, 0.2), mid + 0.01)
        XCTAssertLessThan(grey(bw { $0.bwNeutrals = -1 }, 0.2), mid - 0.01)
        // The ends stay put: black stays black, and white-ish stays near white.
        XCTAssertEqual(grey(bw { $0.bwNeutrals = 1 }, 0.0), 0, accuracy: 0.0005)
        XCTAssertEqual(grey(bw { $0.bwNeutrals = 1 }, 1.0), 1, accuracy: 0.0005)
    }

    func testToneIsAContrastSCurve() {
        let dark = grey(bw(), 0.05), light = grey(bw(), 0.5)
        XCTAssertLessThan(grey(bw { $0.bwTone = 1 }, 0.05), dark, "positive tone darkens the shadows")
        XCTAssertGreaterThan(grey(bw { $0.bwTone = 1 }, 0.5), light, "and lightens the highlights")
        XCTAssertGreaterThan(grey(bw { $0.bwTone = -1 }, 0.05), dark, "negative tone flattens: lifts the shadows")
        XCTAssertLessThan(grey(bw { $0.bwTone = -1 }, 0.5), light)
    }

    func testTheCurvePassesThroughItsDocumentedPerceptualControlPoints() {
        func encode(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        // Perceptual 0.25 -> 0.25 - 0.10 (tone +1), perceptual 0.5 -> 0.5 + 0.12 (neutrals +1), perceptual 0.75 -> 0.75 + 0.10 (tone +1).
        for (p, delta, tone, neutrals) in [(0.25, -0.10, 1.0, 0.0), (0.5, 0.12, 0.0, 1.0), (0.75, 0.10, 1.0, 0.0)] {
            let linear = decode(p)
            let out = Double(grey(bw { $0.bwTone = tone; $0.bwNeutrals = neutrals }, linear))
            XCTAssertEqual(encode(out), p + delta, accuracy: 0.003, "perceptual \(p)")
        }
    }

    func testToneAndNeutralsStayMonotoneAndNeutral() {
        for (t, n) in [(1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0), (0.5, 0.0)] {
            var previous = -Float.infinity
            for v in stride(from: 0.0, through: 1.0, by: 0.05) {
                let out = pixel(EditPipeline.apply(bw { $0.bwTone = t; $0.bwNeutrals = n }, to: solid(v, v, v)))
                XCTAssertGreaterThanOrEqual(out.r, previous - 0.0001, "tone \(t) neutrals \(n) at \(v)")
                XCTAssertEqual(out.r, out.g, accuracy: 0.0001)
                XCTAssertEqual(out.r, out.b, accuracy: 0.0001)
                previous = out.r
            }
        }
    }

    func testAlphaIsUntouchedByTheCurve() {
        let out = pixel(EditPipeline.apply(bw { $0.bwTone = 1; $0.bwNeutrals = 1 }, to: solid(0.4, 0.4, 0.4, a: 0.5)))
        XCTAssertEqual(out.a, 0.5, accuracy: 0.001)
    }

    // MARK: Intensity

    func testIntensityScalesTheMixAndDoesNothingWithoutOne() {
        let blue = solid(0.1, 0.2, 0.8)
        let base = pixel(EditPipeline.apply(bw(), to: blue)).r
        let mixed = pixel(EditPipeline.apply(bw { $0.grayMixBlue = -0.5 }, to: blue)).r
        let stronger = pixel(EditPipeline.apply(bw { $0.grayMixBlue = -0.5; $0.bwIntensity = 1 }, to: blue)).r
        let off = pixel(EditPipeline.apply(bw { $0.grayMixBlue = -0.5; $0.bwIntensity = -1 }, to: blue)).r
        XCTAssertLessThan(mixed, base)
        XCTAssertLessThan(stronger, mixed, "+1 doubles the mix: darker still")
        XCTAssertEqual(off, base, accuracy: 0.0002, "-1 switches the mix off")
        XCTAssertEqual(pixel(EditPipeline.apply(bw { $0.bwIntensity = 1 }, to: blue)).r, base, "with every Mix slider at 0 there is nothing to scale")
    }

    // MARK: Grain

    func testEveryGrainSourceIsSwitchedOffTogetherAndExportAndTheEyedropperUseIt() throws {
        var s = EditState()
        s.blackAndWhite = true; s.grain = 0.2; s.styleGrain = true; s.bwGrain = 0.3
        XCTAssertGreaterThan(EditPipeline.effectiveGrain(s), 0)
        XCTAssertEqual(EditPipeline.effectiveGrain(s.zeroingGrain()), 0)
        XCTAssertTrue(s.zeroingGrain().blackAndWhite, "only grain is touched")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let exporter = try String(contentsOf: root.appendingPathComponent("Sources/Rendering/PhotoExporter.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("Sources/UI/ImageDocumentModel.swift"), encoding: .utf8)
        XCTAssertTrue(exporter.contains("editState.zeroingGrain()"))
        XCTAssertTrue(model.contains("samplingState.zeroingGrain()"))
    }

    func testGrainOnlyCountsWhileBlackAndWhiteIsOnAndAddsToTheGrainSlider() {
        XCTAssertEqual(EditPipeline.effectiveGrain(bw { $0.bwGrain = 0.4 }), 0.4, accuracy: 1e-9)
        XCTAssertEqual(EditPipeline.effectiveGrain(bw { $0.bwGrain = 0.4; $0.grain = 0.3 }), 0.7, accuracy: 1e-9)
        XCTAssertEqual(EditPipeline.effectiveGrain(bw { $0.bwGrain = 0.9; $0.grain = 0.9 }), 1.0, accuracy: 1e-9, "clamped like the Grain slider")
        XCTAssertEqual(EditPipeline.effectiveGrain(EditState(grain: 0.3)), 0.3, accuracy: 1e-9)
    }

    func testGrainChangesTheRenderedPixelsOfAFlatGrey() {
        let flat = solid(0.4, 0.4, 0.4, size: 64)
        let plain = EditPipeline.apply(bw(), to: flat)
        let grainy = EditPipeline.apply(bw { $0.bwGrain = 1 }, to: flat)
        var differing = 0
        for p in stride(from: 0, to: 64, by: 7) where abs(pixel(plain, at: p).r - pixel(grainy, at: p).r) > 0.005 { differing += 1 }
        XCTAssertGreaterThan(differing, 3, "grain visibly varies the flat grey")
    }

    // MARK: Plumbing

    func testCodableDefaultsPresetsCompareAndTheDiffName() throws {
        let decoded = try JSONDecoder().decode(EditState.self, from: Data("{}".utf8))
        XCTAssertEqual([decoded.bwIntensity, decoded.bwNeutrals, decoded.bwTone, decoded.bwGrain], [0, 0, 0, 0])
        var s = EditState()
        s.bwIntensity = 0.1; s.bwNeutrals = -0.2; s.bwTone = 0.3; s.bwGrain = 0.4
        let again = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual([again.bwIntensity, again.bwNeutrals, again.bwTone, again.bwGrain], [0.1, -0.2, 0.3, 0.4])
        let preset = s.applyingPreset(onto: EditState())
        XCTAssertEqual([preset.bwIntensity, preset.bwNeutrals, preset.bwTone, preset.bwGrain], [0.1, -0.2, 0.3, 0.4])
        let original = s.comparisonOriginal()
        XCTAssertEqual([original.bwIntensity, original.bwNeutrals, original.bwTone, original.bwGrain], [0, 0, 0, 0])
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: EditState(), to: s).sorted(), ["bwGrain", "bwIntensity", "bwNeutrals", "bwTone"])
    }

    func testUIHasTheFourSlidersAndResetClearsThem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ui = try String(contentsOf: root.appendingPathComponent("Sources/UI/AdjustTabView.swift"), encoding: .utf8)
        for label in ["Intensity", "Neutrals", "Tone", "Grain"] {
            XCTAssertTrue(ui.contains("label: \"\(label)\", value: $document.editState.bw"), label)
        }
        XCTAssertTrue(ui.contains("state.bwIntensity == 0 && state.bwNeutrals == 0 && state.bwTone == 0 && state.bwGrain == 0"))
        XCTAssertTrue(ui.contains("document.editState.bwIntensity = 0; document.editState.bwNeutrals = 0"))
    }
}
