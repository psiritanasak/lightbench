import XCTest
import CoreImage
@testable import PhotoApp

/// PERMANENT probe for the Lightroom (`crs:`) import (not a throwaway; skips when the files are absent, like `EmbeddedDepthProbeTests`).
///
/// The only full pair available when the import was built: a Nikon D610 NEF (`DSC_5105.NEF`), the Camera Raw 8.5 / PV 6.7 sidecar
/// Lightroom wrote for it (`DSC_5105.xmp`, 102 `crs:` names, Exposure +0.65, Contrast +28, Whites +21, Vibrance +10, Temperature
/// 2400 / Tint +6, no crop) and Lightroom's own 600 x 600 export of it (`DSC_5105.jpg`, a tight portrait crop made in Photoshop,
/// Adobe RGB). It is looked up ONLY in the folder named by the `LIGHTROOM_PROBE_DIR` environment variable (pass
/// `TEST_RUNNER_LIGHTROOM_PROBE_DIR=<a copy of the three files>` to `xcodebuild`); the test host is sandboxed, and probing
/// `~/Desktop` from it stalled on a permission prompt, so it is deliberately not tried. Without the variable this skips.
///
/// WHAT IS MEASURED: the mean absolute difference, per sRGB-encoded channel (0...1), between a 150 x 150 box-average of the Lightroom
/// JPEG and the same region of this app's render of the NEF (decoded by `RawDecoder`, scaled to 1500 px long edge, rotated upright, the
/// region found once by normalised cross-correlation: x 170, y 294 from the top-left, 662 px square, correlation 0.984 on luma with
/// no tone fields applied). ONE PHOTO, ONE PROCESS VERSION. Measured 2026-10-22 by the spike (an equivalent Python reader of the PNGs
/// a throwaway harness rendered); this test reproduces the headline numbers with its own Swift resampler (0.1333 / 0.0671 / 0.0784):
/// - nothing applied (spike figures): 0.1337; Exposure 0.65 only: 0.0669; Exposure + Contrast 0.28 + Whites 0.21 + Vibrance 0.10 (the mapping's
///   output for this file): 0.0781.
/// - Exposure sweep (from the builder's SPIKE, not this test; White Balance FIXED at 3500, nothing else applied): 0.3 -> 0.0586, 0.5 -> 0.0482, 0.65 -> 0.0464, 0.8 -> 0.0461, 1.0 -> 0.0500:
///   the minimum is at 0.65-0.8, consistent with 1 EV per unit.
/// - Imported fields only (Exposure + Whites + Vibrance, Contrast left out): 0.0682; adding the nominal Contrast 0.28 gives 0.0784, the
///   WORSE match that keeps Contrast2012 unimported (the probe asserts that ordering).
/// - Removing one field from the four-field state: without Exposure 0.1126, without Contrast 0.0680, without Whites 0.0767, without
///   Vibrance 0.0774 (against 0.0781 with all four). On THIS photo Contrast and, slightly, Whites and Vibrance move the error the
///   wrong way once Exposure is in: this app's render of the NEF already differs from Camera Raw's in base tone curve (Adobe Standard
///   profile) and highlight roll-off, so a one-photo ablation cannot validate their 1/100 scale. They stay NOMINAL in the mapping.
/// - The White Balance gap is the largest (blue channel mean error -0.23 with nothing applied) but Camera Raw's Temperature is an
///   absolute illuminant (2400) while this app's is relative to 6500, and the as-shot value (3320 K, tint 8.4 from `CIRAWFilter`) is
///   not in the XMP: Temperature / Tint stay UNMAPPED.
final class LightroomImportProbeTests: XCTestCase {
    private func probeFolder() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["LIGHTROOM_PROBE_DIR"] { candidates.append(URL(fileURLWithPath: env)) }
        return candidates.first { dir in
            ["DSC_5105.NEF", "DSC_5105.xmp", "DSC_5105.jpg"].allSatisfy { (try? Data(contentsOf: dir.appendingPathComponent($0), options: .mappedIfSafe)) != nil }
        }
    }

    // MARK: - Pixels

    private static let size = 150
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders `image` (extent anywhere) cropped to `rect` (Core Image, y-up) as RGBA8 sRGB, box-averaged down to `size` x `size`.
    private func reduced(_ image: CIImage, rect: CGRect, context: CIContext) throws -> [Double] {
        let side = Int(rect.width.rounded())
        let cropped = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        context.render(cropped, toBitmap: &bytes, rowBytes: side * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: space)
        let n = Self.size
        var out = [Double](repeating: 0, count: n * n * 3)
        for ty in 0..<n {
            let y0 = Double(ty) * Double(side) / Double(n), y1 = Double(ty + 1) * Double(side) / Double(n)
            for tx in 0..<n {
                let x0 = Double(tx) * Double(side) / Double(n), x1 = Double(tx + 1) * Double(side) / Double(n)
                var sum = [0.0, 0.0, 0.0], weight = 0.0
                for sy in Int(y0)..<min(side, Int(y1.rounded(.up))) {
                    let wy = min(Double(sy + 1), y1) - max(Double(sy), y0)
                    for sx in Int(x0)..<min(side, Int(x1.rounded(.up))) {
                        let w = wy * (min(Double(sx + 1), x1) - max(Double(sx), x0))
                        let i = (sy * side + sx) * 4
                        for c in 0..<3 { sum[c] += w * Double(bytes[i + c]) / 255 }
                        weight += w
                    }
                }
                for c in 0..<3 { out[(ty * n + tx) * 3 + c] = sum[c] / weight }
            }
        }
        return out
    }

    private func meanAbsoluteDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }

    // MARK: - Probe

    func testRealLightroomPairMeasuredAgainstItsOwnRender() async throws {
        guard let folder = probeFolder() else { throw XCTSkip("no Lightroom probe files (DSC_5105.NEF/.xmp/.jpg): skipping") }

        // The real file through the real parser and mapping.
        let settings = try XCTUnwrap(AdobeCameraRawSettings.read(from: folder.appendingPathComponent("DSC_5105.xmp")))
        XCTAssertEqual(settings.number("Exposure2012"), 0.65)
        XCTAssertEqual(settings.number("Contrast2012"), 28)
        XCTAssertEqual(settings.number("Temperature"), 2400)
        XCTAssertEqual(settings.flag("HasCrop"), false)
        XCTAssertEqual(settings.curve("ToneCurvePV2012")?.count, 2)
        let mapping = LightroomMapping.editState(from: settings)
        XCTAssertEqual(mapping.mapped, ["Exposure2012", "Vibrance", "Whites2012"])
        XCTAssertEqual(mapping.state.exposureEV, 0.65, accuracy: 1e-12)
        XCTAssertEqual(mapping.state.contrast, 0, "Contrast is deliberately not imported")
        XCTAssertTrue(mapping.ignored.contains { $0.hasPrefix("Contrast2012") })
        XCTAssertEqual(mapping.state.whites, 0.21, accuracy: 1e-12)
        XCTAssertEqual(mapping.state.vibrance, 0.10, accuracy: 1e-12)
        XCTAssertTrue(mapping.state.toneCurvePoints.isEmpty, "the file's PV2012 curve is straight")
        XCTAssertTrue(mapping.ignored.contains("Temperature") && mapping.ignored.contains("Tint"), "custom white balance is reported, not imported")

        // The renders.
        let decodedOrNil = await RawDecoder.decode(contentsOf: folder.appendingPathComponent("DSC_5105.NEF"), editState: .identity)
        let decoded = try XCTUnwrap(decodedOrNil)
        let long = 1500.0
        let scale = long / max(decoded.extent.width, decoded.extent.height)
        let scaled = decoded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()

        // The spike's registration of the Lightroom crop in the upright 1002 x 1500 render (top-left origin: x 170, y 294, 662 px).
        func region(of render: CIImage) -> CIImage {
            let upright = render.oriented(.left)   // EXIF 8, what the XMP says
            return upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
        }
        let rect = CGRect(x: 170, y: 1500 - 294 - 662, width: 662, height: 662)

        let reference = try XCTUnwrap(CIImage(contentsOf: folder.appendingPathComponent("DSC_5105.jpg")))
        let referencePixels = try reduced(reference, rect: CGRect(x: 0, y: 0, width: 600, height: 600), context: context)

        func error(_ state: EditState) throws -> Double {
            let rendered = region(of: EditPipeline.apply(state, to: scaled))
            XCTAssertEqual(rendered.extent.size, CGSize(width: 1002, height: 1500), "decoded + rotated size")
            return meanAbsoluteDifference(try reduced(rendered, rect: rect, context: context), referencePixels)
        }

        var exposureOnly = EditState.identity
        exposureOnly.exposureEV = mapping.state.exposureEV
        var withContrast = mapping.state
        withContrast.contrast = 0.28   // what a nominal Contrast2012 +28 would have added
        let none = try error(.identity)
        let exposure = try error(exposureOnly)
        let mapped = try error(mapping.state)
        let contrasted = try error(withContrast)
        print("LIGHTROOM PROBE mean abs difference (150 px, sRGB 0...1): none \(none), exposure only \(exposure), mapped \(mapped), mapped + contrast 0.28 \(contrasted)")

        // Spike figures (Python resampler): none 0.1337, exposure only 0.0669, the old four-field state with contrast 0.0781.
        XCTAssertEqual(none, 0.1337, accuracy: 0.01)
        XCTAssertEqual(exposure, 0.0669, accuracy: 0.01)
        XCTAssertEqual(contrasted, 0.0781, accuracy: 0.01)
        // The SIGN is the point (a loose tolerance would hide it): once Exposure is matched, adding the nominal Contrast moves the render
        // AWAY from Lightroom's, which is why Contrast2012 is not imported.
        XCTAssertGreaterThan(contrasted, mapped, "contrast must make the match worse")
        XCTAssertGreaterThan(contrasted, exposure)
        XCTAssertLessThan(exposure, none / 1.5, "Exposure alone closes much of the gap: the one measured-consistent field")
        XCTAssertLessThan(mapped, none, "the imported fields together still beat doing nothing")
    }
}
