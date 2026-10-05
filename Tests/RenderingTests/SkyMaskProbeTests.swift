import CoreGraphics
import Vision
import XCTest

/// PERMANENT feasibility probe for an AI "Sky" mask (same role as `VisionSubjectMaskProbeTests`). Nothing in `Sources/`
/// uses it: this pins the few OS facts the 2026-10-05 spike's decision rests on (see docs/ROADMAP_HISTORY.md "Sky / Object
/// mask feasibility spike"). Skips only when an API ERRORS or returns nothing; it FAILS when the SHAPE changes (a dropped or
/// renamed classifier label, a different saliency format), because the spike's gate decision depends on those exact facts.
final class SkyMaskProbeTests: XCTestCase {
    /// Deep blue at the top fading to pale near a green "ground" band — a crude but unmistakable sky-over-land picture.
    private static func skyOverLandFixture() throws -> CGImage {
        let width = 600, height = 400
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 0.12, green: 0.35, blue: 0.85, alpha: 1), CGColor(red: 0.65, green: 0.8, blue: 0.95, alpha: 1)] as CFArray,
            locations: [0, 1]))
        // CGContext's origin is bottom-left: the gradient runs from the TOP edge (y = height) down to 35% height.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: CGFloat(height) * 0.35), options: [])
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: Int(Double(height) * 0.35)))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// The classifier's vocabulary contains the sky labels a gate would use. A SCENE gate (does this photo contain sky?),
    /// not a mask: `VNClassifyImageRequest` returns one confidence per label for the whole image.
    func testClassifierVocabularyHasTheSkyLabels() throws {
        // Measured 2026-10-05 (Apple M1, macOS 27.0 build 26A428): revision 2 is the default and current revision
        // (revisions 1 and 2 supported), 1303 labels. Pinned so a future SDK's new default cannot silently change what is checked.
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        let identifiers: [String]
        do { identifiers = try request.supportedIdentifiers() } catch { throw XCTSkip("classifier vocabulary unavailable: \(error)") }
        for label in ["sky", "blue_sky", "cloudy", "sunset_sunrise", "night_sky"] {
            XCTAssertTrue(identifiers.contains(label), "\(label) is not in the classifier vocabulary (\(identifiers.count) labels)")
        }
    }

    /// A blue-gradient-over-green-band fixture classifies as sky. Measured on the dev machine (Apple M1, macOS 27.0 build 26A428, revision 2):
    /// `blue_sky`, `outdoor` and `sky` all 0.78 (next label 0.01), so the 0.3 floor leaves a wide margin. SKIP-ONLY: below the floor this test
    /// skips (a hint to re-check the gate) rather than fails, because classifier confidences on a synthetic image are OS-model dependent.
    func testSkyOverLandFixtureClassifiesAsSky() throws {
        let image = try Self.skyOverLandFixture()
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { throw XCTSkip("classification failed: \(error)") }
        let results = request.results ?? []
        let sky = results.first { $0.identifier == "sky" }?.confidence ?? 0
        let blueSky = results.first { $0.identifier == "blue_sky" }?.confidence ?? 0
        guard max(sky, blueSky) >= 0.3 else {
            throw XCTSkip("the synthetic fixture did not classify as sky on this OS (top: \(results.prefix(4).map { "\($0.identifier) \($0.confidence)" })) — re-check the spike's gate")
        }
    }

    /// Attention saliency is a COARSE heat map — a poor sky mask by itself (the spike measured it lower inside the sky mask in
    /// most photos, inconsistently and only marginally in several). Pin the one structural fact: a small fixed-size float map, not an image-sized mask.
    func testSaliencyIsACoarseFixedSizeHeatMap() throws {
        let image = try Self.skyOverLandFixture()
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { throw XCTSkip("saliency failed: \(error)") }
        guard let heat = request.results?.first?.pixelBuffer else { throw XCTSkip("no saliency result") }
        XCTAssertLessThan(CVPixelBufferGetWidth(heat), 200, "far coarser than a 600px image: not a boundary-quality mask")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(heat), kCVPixelFormatType_OneComponent32Float)
    }
}
