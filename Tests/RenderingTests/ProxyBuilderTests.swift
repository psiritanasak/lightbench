import XCTest
@testable import PhotoApp

final class ProxyBuilderTests: XCTestCase {
    func testResultIsRealizedNotLazy() async {
        // The entire reason this type exists (per its own doc comment,
        // quoting RawDecoder.materialize's "a CIImage is a lazy recipe, not
        // decoded pixels" argument): a regression that dropped the
        // CVPixelBufferCreate/render step and returned the lazy Lanczos
        // graph directly would look correct in every other test in this
        // file, but would silently reintroduce a full-resolution resample
        // on every drag frame — making the whole P2 feature a no-op while
        // still LOOKING right.
        //
        // `CIImage.pixelBuffer` and `.description` were both measured NOT
        // to distinguish the two cases (reviewer-verified: `.pixelBuffer`
        // returns `nil` once the required `.colorSpace` option is passed to
        // `CIImage(cvPixelBuffer:options:)`, which this type's production
        // code must do for correct `extendedLinearSRGB` tagging; and
        // `.description` prints only the extent for both a lazy graph and a
        // realized image). The discriminator that DOES work: mutate the
        // SOURCE buffer's bytes AFTER building the proxy. A realized proxy
        // is decoupled from the source and keeps the value it was built
        // with; a lazy graph would re-read the mutated source on render.
        let size = 64
        guard let sourceBuffer = makeConstantPixelBuffer(size: size, value: 0.5) else {
            return XCTFail("failed to create source pixel buffer")
        }
        let source = CIImage(cvPixelBuffer: sourceBuffer, options: [.colorSpace: ProxyBuilder.colorSpace])

        guard let proxy = await ProxyBuilder.build(source, scale: 0.5) else {
            return XCTFail("proxy build failed")
        }

        fillPixelBuffer(sourceBuffer, value: 1.0)

        let result = sampleExtendedRangePixel(proxy, at: CGPoint(x: size / 4, y: size / 4))
        XCTAssertEqual(
            Double(result.0), 0.5, accuracy: 0.05,
            "a realized proxy must keep the value it was built with, not re-read the mutated source"
        )
    }

    func testOutputPixelSizeMatchesRequestedScale() async {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let image = CIImage(color: CIColor(red: 0.6, green: 0.2, blue: 0.8)).cropped(to: extent)

        guard let proxy = await ProxyBuilder.build(image, scale: 0.5) else {
            return XCTFail("proxy build failed")
        }

        // Exact, not `accuracy: 1` — these are whole-pixel buffer dimensions
        // computed by rounding, and the off-by-one this math is most
        // exposed to is exactly what a loose accuracy would hide.
        XCTAssertEqual(proxy.extent.width, 100)
        XCTAssertEqual(proxy.extent.height, 50)
    }

    func testOutputPixelSizeRoundsForANonIntegerScaledDimension() async {
        // 201x101 at 0.5 scale gives a true content size of 100.5x50.5 —
        // the one path where `sourceRect` (rounded up to 101x51) genuinely
        // exceeds the real scaled content and relies on the `.clampedToExtent()`
        // edge-replication fix to fill the extra half-pixel rather than
        // exposing a dark/transparent sliver. Every other fixture in this
        // file is even x even at scale 0.5, which never rounds at all.
        let extent = CGRect(x: 0, y: 0, width: 201, height: 101)
        let image = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: extent)

        guard let proxy = await ProxyBuilder.build(image, scale: 0.5) else {
            return XCTFail("proxy build failed")
        }

        XCTAssertEqual(proxy.extent.width, 101)
        XCTAssertEqual(proxy.extent.height, 51)
        let corner = sampleExtendedRangePixel(proxy, at: CGPoint(x: 100, y: 50))
        let center = sampleExtendedRangePixel(proxy, at: CGPoint(x: 50, y: 25))
        XCTAssertEqual(Double(corner.0), Double(center.0), accuracy: 0.02, "red")
        XCTAssertEqual(Double(corner.3), Double(center.3), accuracy: 0.02, "alpha")
    }

    func testOutputIsAtOriginZeroRegardlessOfSourceOrigin() async {
        // The source has a non-zero, non-integer-after-scaling origin —
        // pins that the builder emits at (0,0) rather than a fractional
        // scaled origin (this function's own documented design choice).
        let extent = CGRect(x: 17, y: 23, width: 200, height: 100)
        let image = CIImage(color: CIColor(red: 0.6, green: 0.2, blue: 0.8)).cropped(to: extent)

        let proxy = await ProxyBuilder.build(image, scale: 0.5)

        XCTAssertEqual(proxy?.extent.origin, .zero)
    }

    func testExtendedRangeValuesSurviveTheRoundTrip() async {
        // Same fixture shape as RawDecoderTests'
        // testMaterializePreservesExtendedRangeValuesBeyondSRGBGamut: an
        // 8-bit/sRGB intermediate would silently clip this, which is
        // exactly the defect class this function's doc comment warns
        // about avoiding (the thumbnail pipeline's own reviewer-caught
        // regression).
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        guard let hdrColor = CIColor(
            red: 3.5, green: 1.8, blue: -0.25, alpha: 1, colorSpace: ProxyBuilder.colorSpace
        ) else {
            return XCTFail("could not construct an extended-range CIColor")
        }
        let image = CIImage(color: hdrColor).cropped(to: extent)
        let center = CGPoint(x: 4, y: 4) // center of the scaled (8x8) output

        guard let proxy = await ProxyBuilder.build(image, scale: 0.5) else {
            return XCTFail("proxy build failed")
        }
        let result = sampleExtendedRangePixel(proxy, at: center)

        XCTAssertEqual(Double(result.0), 3.5, accuracy: 0.05, "red")
        XCTAssertEqual(Double(result.1), 1.8, accuracy: 0.05, "green")
        XCTAssertEqual(Double(result.2), -0.25, accuracy: 0.05, "blue")
        // The real regression guard, not just the equality checks above:
        // confirm the value genuinely survived OUTSIDE [0,1] rather than
        // having been clamped into range by a lossy intermediate.
        XCTAssertGreaterThan(result.0, 1.0, "red should retain extended-range headroom above 1.0")
        XCTAssertLessThan(result.2, 0.0, "blue should retain a negative/out-of-gamut value")
    }

    func testCornerPixelIsNotDarkenedByLanczosSampling() async {
        // Pins the `.clampedToExtent()` fix: without it, Lanczos samples
        // outside the source's bounds at the CORNERS, pulling in
        // transparent black and darkening/de-opaquing that pixel relative
        // to the uniform solid color everywhere else. Reviewer-measured:
        // sampling at (1,1) (one pixel in from the corner) stays inside
        // tolerance even with the clamp removed — Lanczos's ringing
        // actually overshoots BRIGHT one pixel in, so that point doesn't
        // discriminate. The true corner pixel (0,0) is where the
        // darkening is actually measurable, and alpha (which should stay
        // exactly 1 across a fully opaque source) is the cleaner signal
        // than color, which has some tolerance-masked ringing either way.
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let image = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: extent)

        guard let proxy = await ProxyBuilder.build(image, scale: 0.5) else {
            return XCTFail("proxy build failed")
        }
        let center = sampleExtendedRangePixel(proxy, at: CGPoint(x: 16, y: 16))
        let corner = sampleExtendedRangePixel(proxy, at: CGPoint(x: 0, y: 0))

        XCTAssertEqual(Double(corner.0), Double(center.0), accuracy: 0.02, "red")
        XCTAssertEqual(Double(corner.1), Double(center.1), accuracy: 0.02, "green")
        XCTAssertEqual(Double(corner.2), Double(center.2), accuracy: 0.02, "blue")
        XCTAssertEqual(Double(corner.3), Double(center.3), accuracy: 0.02, "alpha")
    }

    func testInfiniteExtentReturnsNil() async {
        let infinite = CIImage(color: .red) // .extent == .infinite, no crop
        XCTAssertTrue(infinite.extent.isInfinite, "test premise: CIImage(color:) is unbounded until cropped")

        let proxy = await ProxyBuilder.build(infinite, scale: 0.5)

        XCTAssertNil(proxy)
    }

    func testNullExtentReturnsNil() async {
        let proxy = await ProxyBuilder.build(CIImage.empty(), scale: 0.5)
        XCTAssertNil(proxy)
    }

    func testDegenerateScaleReturnsNil() async {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let image = CIImage(color: .red).cropped(to: extent)

        let zero = await ProxyBuilder.build(image, scale: 0)
        let negative = await ProxyBuilder.build(image, scale: -0.5)
        let nan = await ProxyBuilder.build(image, scale: .nan)
        let aboveOne = await ProxyBuilder.build(image, scale: 2)
        // The actual crash repro this guard exists for (reviewer-caught):
        // without an upper bound, `extent.width * scale` can exceed
        // `Int64.max` and `Int(_:)` traps on the conversion — asserting
        // this returns `nil` rather than crashing IS the regression test.
        let pathological = await ProxyBuilder.build(image, scale: .greatestFiniteMagnitude)

        XCTAssertNil(zero)
        XCTAssertNil(negative)
        XCTAssertNil(nan)
        XCTAssertNil(aboveOne)
        XCTAssertNil(pathological)
    }

    // MARK: - Helpers

    /// Same shape as `RawDecoderTests`' own extended-range sampler: reads
    /// back as `Float`/`.RGBAf` through a context whose OWN working space
    /// is also extended, so a plain default `CIContext()` sampler can't
    /// mask a clipping regression before the test could observe it.
    private static let extendedRangeSamplingContext = CIContext(options: [
        .workingColorSpace: ProxyBuilder.colorSpace,
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
            colorSpace: ProxyBuilder.colorSpace
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    /// A `kCVPixelFormatType_64RGBAHalf` buffer of solid `value` (opaque),
    /// for `testResultIsRealizedNotLazy`'s mutate-the-source probe — this
    /// needs a buffer we hold a reference to and can rewrite in place,
    /// unlike every other fixture in this file (`CIImage(color:)`, which
    /// has no mutable backing to rewrite).
    private func makeConstantPixelBuffer(size: Int, value: Float) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, size, size,
            kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        fillPixelBuffer(pixelBuffer, value: value)
        return pixelBuffer
    }

    private func fillPixelBuffer(_ pixelBuffer: CVPixelBuffer, value: Float) {
        // Asserted, not discarded: a silent lock failure here specifically
        // for the POST-BUILD mutation in `testResultIsRealizedNotLazy`
        // would leave the source unmutated and turn that test into a false
        // pass (reviewer-flagged) — essentially impossible for a freshly
        // created, unlocked buffer, but cheap to make impossible outright.
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        XCTAssertEqual(lockStatus, kCVReturnSuccess, "failed to lock pixel buffer for writing")
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let channelBits = Float16(value).bitPattern
        let alphaBits = Float16(1).bitPattern
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = channelBits
                row[offset + 1] = channelBits
                row[offset + 2] = channelBits
                row[offset + 3] = alphaBits
            }
        }
    }
}
