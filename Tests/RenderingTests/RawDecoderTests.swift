import CoreImage
import XCTest
@testable import PhotoApp

/// `RawDecoder.isRaw(_:)` is pure UTType classification, tested against
/// filenames only — no real RAW fixture needed (decode itself needs a real
/// RAW file and is covered by the live-verification pass, not asserted
/// here). `RawDecoder.decode`/`decodeDraft`'s non-RAW behavior is exercised
/// indirectly by `ThumbnailGeneratorTests`/`PhotoExporterTests`, which
/// already write real non-RAW fixtures and would fail if the RawDecoder
/// substitution changed non-RAW output. `RawDecoder.materialize`, unlike
/// the rest of this type, needs no RAW file at all — it operates on any
/// `CIImage`, so it's tested against a synthetic in-memory one (same
/// `CIImage(color:).cropped(to:)` pattern `ThumbnailGeneratorTests` uses).
final class RawDecoderTests: XCTestCase {
    func testClassifiesCommonRawExtensionsAsRaw() {
        let rawExtensions = ["nef", "cr2", "cr3", "arw", "dng", "raf", "orf", "rw2"]
        for ext in rawExtensions {
            let url = URL(fileURLWithPath: "/tmp/photo.\(ext)")
            XCTAssertTrue(RawDecoder.isRaw(url), "\(ext) should classify as RAW")
        }
    }

    func testClassifiesRawExtensionsCaseInsensitively() {
        XCTAssertTrue(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/DSC_1017.NEF")))
        XCTAssertTrue(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/IMG_0001.CR2")))
    }

    func testDoesNotClassifyNonRawImageExtensionsAsRaw() {
        let nonRawExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "heic"]
        for ext in nonRawExtensions {
            let url = URL(fileURLWithPath: "/tmp/photo.\(ext)")
            XCTAssertFalse(RawDecoder.isRaw(url), "\(ext) should not classify as RAW")
        }
    }

    func testDoesNotClassifyNonImageOrUnknownExtensionsAsRaw() {
        XCTAssertFalse(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/edits.photoapp.json")))
        XCTAssertFalse(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/no-extension")))
    }

    func testDecodeReturnsNilForAMissingFileRegardlessOfExtension() async {
        let rawResult = await RawDecoder.decode(contentsOf: URL(fileURLWithPath: "/tmp/does-not-exist.nef"))
        XCTAssertNil(rawResult)
        let nonRawResult = await RawDecoder.decode(contentsOf: URL(fileURLWithPath: "/tmp/does-not-exist.jpg"))
        XCTAssertNil(nonRawResult)
    }

    func testDecodeDraftReturnsNilForAMissingFile() async {
        let result = await RawDecoder.decodeDraft(contentsOf: URL(fileURLWithPath: "/tmp/does-not-exist.nef"), maxPixelSize: 256)
        XCTAssertNil(result)
    }

    // MARK: - materialize

    func testMaterializePreservesExtentIncludingNonZeroOrigin() async {
        let extent = CGRect(x: 10, y: 20, width: 64, height: 48)
        let image = CIImage(color: CIColor(red: 0.6, green: 0.2, blue: 0.8)).cropped(to: extent)

        let materialized = await RawDecoder.materialize(image)

        XCTAssertEqual(materialized.extent, extent)
    }

    func testMaterializePreservesPixelColor() async {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        let image = CIImage(color: CIColor(red: 0.6, green: 0.2, blue: 0.8)).cropped(to: extent)
        let center = CGPoint(x: 16, y: 16)

        let materialized = await RawDecoder.materialize(image)

        let originalPixel = samplePixel(image, at: center)
        let materializedPixel = samplePixel(materialized, at: center)
        for channel in 0..<3 {
            XCTAssertEqual(
                Double(originalPixel[channel]), Double(materializedPixel[channel]), accuracy: 3,
                "channel \(channel) drifted too far across materialize"
            )
        }
    }

    func testMaterializePreservesExtendedRangeValuesBeyondSRGBGamut() async {
        // Reviewer-caught gap: `testMaterializePreservesPixelColor` above
        // only used in-gamut [0,1] input, sampled through an 8-bit RGBA8
        // bitmap — a naive 8-bit/sRGB-intermediate reimplementation of
        // `materialize` (exactly the defect class this function's own doc
        // comment claims to avoid — the same one the reviewer caught in the
        // thumbnail path during this feature's original review) passes
        // that test with ZERO measured drift, because both the correct and
        // the broken implementation clip to the same 8-bit range the TEST
        // itself samples through. This test uses values OUTSIDE [0,1],
        // sampled as float in the app's own extended working space, so a
        // silent-clipping regression fails here instead of going undetected.
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        guard let hdrColor = CIColor(
            red: 3.5, green: 1.8, blue: -0.25, alpha: 1, colorSpace: RawDecoder.materializeColorSpace
        ) else {
            return XCTFail("could not construct an extended-range CIColor")
        }
        let image = CIImage(color: hdrColor).cropped(to: extent)
        let center = CGPoint(x: 4, y: 4)

        let materialized = await RawDecoder.materialize(image)

        let original = sampleExtendedRangePixel(image, at: center)
        let result = sampleExtendedRangePixel(materialized, at: center)
        XCTAssertEqual(Double(original.0), Double(result.0), accuracy: 0.01, "red")
        XCTAssertEqual(Double(original.1), Double(result.1), accuracy: 0.01, "green")
        XCTAssertEqual(Double(original.2), Double(result.2), accuracy: 0.01, "blue")
        // The real regression guard: confirm the value genuinely survived
        // OUTSIDE [0,1] rather than both sides having been clamped into
        // range by the same lossy path (which would still pass the
        // equality assertions above).
        XCTAssertGreaterThan(result.0, 1.0, "red should retain extended-range headroom above 1.0")
        XCTAssertLessThan(result.2, 0.0, "blue should retain a negative/out-of-gamut value")
    }

    func testMaterializeReturnsInputUnchangedForAnInfiniteExtent() async {
        // `CGRect.infinite`'s width/height are `CGFloat.greatestFiniteMagnitude`
        // — finite by IEEE semantics, NOT `.infinity` — so this deliberately
        // does not assert via `.isFinite`; `CGRect.isInfinite` is the correct
        // check, and is what `materialize` itself must guard with too.
        let infinite = CIImage(color: .red) // .extent == .infinite, no crop
        XCTAssertTrue(infinite.extent.isInfinite, "test premise: CIImage(color:) is unbounded until cropped")

        let materialized = await RawDecoder.materialize(infinite)

        XCTAssertTrue(materialized.extent.isInfinite)
    }

    private func samplePixel(_ image: CIImage, at point: CGPoint) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            image,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixel
    }

    /// Unlike `samplePixel` above, this reads back as `Float`/`.RGBAf` and
    /// renders through a context whose OWN working space is also extended
    /// (`RawDecoder.materializeColorSpace`/`.RGBAf`) — a plain default
    /// `CIContext()` used for the measurement itself would clip extended
    /// values before this test could observe whether `materialize` did.
    private static let extendedRangeSamplingContext = CIContext(options: [
        .workingColorSpace: RawDecoder.materializeColorSpace,
        .workingFormat: CIFormat.RGBAf
    ])

    private func sampleExtendedRangePixel(_ image: CIImage, at point: CGPoint) -> (Float, Float, Float, Float) {
        var pixel = [Float](repeating: 0, count: 4)
        Self.extendedRangeSamplingContext.render(
            image,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: RawDecoder.materializeColorSpace
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
