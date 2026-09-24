import CoreImage
import Metal
import MetalFX
import XCTest
@testable import PhotoApp

/// Step 0 of the Enhance/Super Resolution feature (CLAUDE.md's own
/// "never write measurement-shaped prose you have not run" convention):
/// before any production code is built around `MTLFXSpatialScaler`, this
/// probe exercises the REAL framework on THIS machine and settles two
/// things no amount of reading documentation can: whether the scaler
/// actually constructs/encodes here, and whether the `CIImage(mtlTexture:)`
/// round trip preserves orientation (`PhotoExporter`'s own doc comment
/// warns this must be independently verified per offscreen-texture path,
/// never assumed — the same landmine that path already documents).
///
/// `XCTSkip`s (not fails) when there's no Metal device or the device
/// doesn't support MetalFX spatial scaling — a real, expected outcome on
/// some hardware, not a bug. If this ever skips in CI/on a dev machine
/// that's supposed to support it, `SuperResolutionUpscaler` (not yet
/// written) must ship Lanczos-only, per the plan's own decision point.
final class SuperResolutionUpscalerTests: XCTestCase {
    func testMetalFXSpatialScalerProbe() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine.")
        }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            throw XCTSkip("\(device.name) does not support MetalFX spatial scaling.")
        }

        let inputSize = 64
        let outputSize = 128

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputSize
        descriptor.inputHeight = inputSize
        descriptor.outputWidth = outputSize
        descriptor.outputHeight = outputSize
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.outputTextureFormat = .rgba16Float
        // `.perceptual` mode expects gamma-encoded (display-referred) 0...1
        // values, NOT this project's usual `extendedLinearSRGB` working
        // space (reviewer-caught while reviewing this very probe, before
        // any production code existed to get it wrong first). What makes
        // that pairing correct here is NOT the context's `workingColorSpace`
        // option below — that only controls the internal filter-graph
        // compute space — it's that `context.render(_:to:commandBuffer:
        // bounds:colorSpace:)`'s own `colorSpace:` argument converts to
        // that space AS it writes into the destination texture, the same
        // mechanism `PhotoExporter.write`'s `colorSpace: outputColorSpace`
        // argument already uses for its JPEG/PNG/TIFF writers. Production
        // (`SuperResolutionUpscaler.metalFXUpscale`) MUST pass an sRGB
        // (gamma) `colorSpace:` to that render call — passing the
        // extended-linear WORKING space there instead would silently feed
        // `.perceptual` linear data, a real image-math bug, not just a
        // style choice.
        descriptor.colorProcessingMode = .perceptual

        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            return XCTFail("MTLFXSpatialScalerDescriptor.makeSpatialScaler(device:) returned nil despite supportsDevice == true")
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: colorSpace])

        // An asymmetric fixture: RED only in one specific corner (Core
        // Image's own bottom-left-origin coordinate space — x in
        // [0,16), y in [48,64), i.e. visually top-left), BLUE everywhere
        // else. If the MetalFX round trip silently flips the image
        // vertically (the exact hazard `PhotoExporter`'s doc comment
        // warns about for a DIFFERENT offscreen-texture path), the red
        // patch will show up at the BOTTOM instead of the top of the
        // upscaled output, and this test will catch it directly rather
        // than trusting the framework's documented behavior.
        // A mid-gray patch is layered in too: pure red/blue survive any
        // transfer-curve mistake (a missed linearize, a double gamma
        // encode, a wrong `colorSpace:` tag) completely unchanged, so on
        // their own they cannot catch that class of bug — only orientation.
        // 0.5 gamma-sRGB is far enough from both 0.5 linear and any simple
        // double-encode of either to actually discriminate.
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
        let redPatch = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 48, width: 16, height: 16))
        let grayPatch = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 48, y: 0, width: 16, height: 16))
        let fixture = redPatch.composited(over: grayPatch.composited(over: blue))

        // Usage flags union what the SCALER itself declares it needs
        // (`colorTextureUsage`/`outputTextureUsage` — reviewer-caught: a
        // fixed guess happened to work on this M1, but isn't guaranteed
        // portable across GPU families) with what CORE IMAGE separately
        // needs for its own half of the round trip: `.shaderWrite` +
        // `.renderTarget` to render INTO the input texture, `.shaderRead`
        // to read the output texture back out. Dropping either union
        // member breaks silently, not loudly — confirmed by a real,
        // temporarily-introduced regression during this test's own
        // development: with only the scaler's own declared usage, Core
        // Image's render call failed silently ("the destination is nil")
        // and every sample read back as (0,0,0,1), which would have
        // looked like a real color/orientation bug rather than a missing
        // texture-usage flag.
        guard
            let inputTexture = Self.makeTexture(
                device: device, width: inputSize, height: inputSize,
                usage: scaler.colorTextureUsage.union([.shaderWrite, .renderTarget])
            ),
            let outputTexture = Self.makeTexture(
                device: device, width: outputSize, height: outputSize,
                usage: scaler.outputTextureUsage.union([.shaderRead])
            )
        else {
            return XCTFail("failed to allocate MetalFX probe textures")
        }

        guard let commandQueue = device.makeCommandQueue(), let commandBuffer = commandQueue.makeCommandBuffer() else {
            return XCTFail("failed to create a Metal command buffer")
        }

        context.render(fixture, to: inputTexture, commandBuffer: commandBuffer, bounds: fixture.extent, colorSpace: colorSpace)

        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed, "MetalFX encode did not complete: \(commandBuffer.error?.localizedDescription ?? "unknown error")")
        guard commandBuffer.status == .completed else { return }

        let result = CIImage(mtlTexture: outputTexture, options: [.colorSpace: colorSpace])
        XCTAssertNotNil(result, "CIImage(mtlTexture:) returned nil for the MetalFX output texture")
        guard let result else { return }

        // Scaled: the red corner (x:[0,16), y:[48,64)) becomes roughly
        // (x:[0,32), y:[96,128)) at 2x. Sample well inside that region.
        let topLeft = Self.sampleColor(result, at: CGPoint(x: 8, y: 112), context: context, colorSpace: colorSpace)
        XCTAssertGreaterThan(topLeft.0, 0.6, "expected the marked corner to read as red (r), got \(topLeft)")
        XCTAssertLessThan(topLeft.2, 0.4, "expected the marked corner to read as red (not blue), got \(topLeft)")

        // The vertically-flipped mirror position: if the round trip
        // introduced a y-flip, THIS is where the red patch would
        // actually land instead. Must read as blue.
        let bottomLeft = Self.sampleColor(result, at: CGPoint(x: 8, y: 16), context: context, colorSpace: colorSpace)
        XCTAssertLessThan(bottomLeft.0, 0.4, "expected the flip-check corner to read as blue (not red) — a red reading here means the round trip flips vertically, got \(bottomLeft)")
        XCTAssertGreaterThan(bottomLeft.2, 0.6, "expected the flip-check corner to read as blue, got \(bottomLeft)")

        // Gray patch (x:[48,64), y:[0,16)) becomes roughly (x:[96,128),
        // y:[0,32)) at 2x — a corner distinct from both red-check points
        // above, so this assertion is additive, not a re-check of the
        // same pixels. A transfer-curve bug would show up here as a value
        // well outside this tolerance (e.g. ~0.21 for a missed linearize
        // of 0.5 gamma-sRGB, or ~0.75 for a spurious double encode).
        let grayPoint = Self.sampleColor(result, at: CGPoint(x: 112, y: 8), context: context, colorSpace: colorSpace)
        XCTAssertEqual(grayPoint.0, 0.5, accuracy: 0.05, "gray patch red channel drifted — possible color-space/transfer-curve corruption, got \(grayPoint)")
        XCTAssertEqual(grayPoint.1, 0.5, accuracy: 0.05, "gray patch green channel drifted — possible color-space/transfer-curve corruption, got \(grayPoint)")
        XCTAssertEqual(grayPoint.2, 0.5, accuracy: 0.05, "gray patch blue channel drifted — possible color-space/transfer-curve corruption, got \(grayPoint)")
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Renders `image` to an 8-bit RGBA bitmap and reads back one pixel —
    /// simple and precise enough for this probe's "is it red or blue"
    /// question; not intended as a general-purpose sampler.
    private static func sampleColor(_ image: CIImage, at point: CGPoint, context: CIContext, colorSpace: CGColorSpace) -> (Double, Double, Double, Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(
                image, toBitmap: buffer.baseAddress!, rowBytes: 4, bounds: rect,
                format: .RGBA8, colorSpace: colorSpace
            )
        }
        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0, Double(pixel[3]) / 255.0)
    }
}

// MARK: - SuperResolutionUpscaler unit tests

extension SuperResolutionUpscalerTests {
    // MARK: outputPixelSize

    func testOutputPixelSizeExactlyDoublesAWellFormedExtent() {
        let result = SuperResolutionUpscaler.outputPixelSize(for: CGRect(x: 0, y: 0, width: 100, height: 60))
        XCTAssertEqual(result?.width, 200)
        XCTAssertEqual(result?.height, 120)
    }

    func testOutputPixelSizeRejectsInfiniteExtent() {
        XCTAssertNil(SuperResolutionUpscaler.outputPixelSize(for: .infinite))
    }

    func testOutputPixelSizeRejectsNullExtent() {
        XCTAssertNil(SuperResolutionUpscaler.outputPixelSize(for: .null))
    }

    func testOutputPixelSizeRejectsZeroSizeExtent() {
        XCTAssertNil(SuperResolutionUpscaler.outputPixelSize(for: CGRect(x: 0, y: 0, width: 0, height: 50)))
        XCTAssertNil(SuperResolutionUpscaler.outputPixelSize(for: CGRect(x: 0, y: 0, width: 50, height: 0)))
    }

    func testOutputPixelSizeRejectsAnExtentThatWouldOverflowOnDoubling() {
        let huge = CGRect(x: 0, y: 0, width: CGFloat(Int32.max), height: 100)
        XCTAssertNil(SuperResolutionUpscaler.outputPixelSize(for: huge))
    }

    // MARK: plannedMethod

    func testPlannedMethodFallsBackWithNoDevice() {
        let (method, reason) = SuperResolutionUpscaler.plannedMethod(
            outputWidth: 100, outputHeight: 100, hasDevice: false, deviceSupportsMetalFX: false
        )
        XCTAssertEqual(method, .lanczos)
        XCTAssertEqual(reason, .noMetalDevice)
    }

    func testPlannedMethodFallsBackWhenDeviceDoesNotSupportMetalFX() {
        let (method, reason) = SuperResolutionUpscaler.plannedMethod(
            outputWidth: 100, outputHeight: 100, hasDevice: true, deviceSupportsMetalFX: false
        )
        XCTAssertEqual(method, .lanczos)
        XCTAssertEqual(reason, .deviceUnsupported)
    }

    func testPlannedMethodFallsBackAboveMaxTextureDimension() {
        let over = SuperResolutionUpscaler.maxTextureDimension + 2
        let (method, reason) = SuperResolutionUpscaler.plannedMethod(
            outputWidth: over, outputHeight: 100, hasDevice: true, deviceSupportsMetalFX: true
        )
        XCTAssertEqual(method, .lanczos)
        XCTAssertEqual(reason, .exceedsMaxTextureSize)
    }

    func testPlannedMethodAllowsExactlyMaxTextureDimension() {
        let max = SuperResolutionUpscaler.maxTextureDimension
        let (method, reason) = SuperResolutionUpscaler.plannedMethod(
            outputWidth: max, outputHeight: max, hasDevice: true, deviceSupportsMetalFX: true
        )
        XCTAssertEqual(method, .metalFX)
        XCTAssertNil(reason)
    }

    func testPlannedMethodPicksMetalFXWhenEverythingChecksOut() {
        let (method, reason) = SuperResolutionUpscaler.plannedMethod(
            outputWidth: 100, outputHeight: 100, hasDevice: true, deviceSupportsMetalFX: true
        )
        XCTAssertEqual(method, .metalFX)
        XCTAssertNil(reason)
    }

    // MARK: Lanczos path

    func testLanczosUpscaleProducesExactlyDoubledExtentAtOrigin() {
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        guard let result = SuperResolutionUpscaler.lanczosUpscale(source) else {
            return XCTFail("lanczosUpscale returned nil")
        }
        XCTAssertEqual(result.extent, CGRect(x: 0, y: 0, width: 40, height: 20))
    }

    func testLanczosUpscaleReOriginsANonZeroOriginInputToExactlyDoubledExtent() {
        // A crop can leave a non-zero origin (e.g. after this app's own
        // crop pipeline stage) — the result must still be an exact
        // (0, 0, 2w, 2h) rect, matching ProxyBuilder.build's own
        // documented re-origining behavior, since nothing downstream
        // needs the source's absolute origin preserved.
        //
        // Reviewer-caught: an extent-only assertion here can't actually
        // tell "correctly re-origined" apart from "content landed
        // somewhere else entirely, but happens to have the right
        // bounding box" — the crop-then-translate math guarantees the
        // EXTENT regardless of where the source content lands. Using the
        // asymmetric fixture, offset to this same non-zero origin, and
        // sampling its marked corner closes that gap.
        let fixture = Self.makeAsymmetricFixture(width: 32, height: 32)
            .transformed(by: CGAffineTransform(translationX: 10, y: 5))
        guard let result = SuperResolutionUpscaler.lanczosUpscale(fixture) else {
            return XCTFail("lanczosUpscale returned nil")
        }
        XCTAssertEqual(result.extent, CGRect(x: 0, y: 0, width: 64, height: 64))
        let topLeft = Self.sampleColor(result, at: CGPoint(x: 4, y: 56), context: Self.testContext, colorSpace: Self.testColorSpace)
        XCTAssertGreaterThan(topLeft.0, 0.6, "expected the marked corner to read as red after re-origining, got \(topLeft)")
        XCTAssertLessThan(topLeft.2, 0.4, "expected the marked corner to read as red after re-origining, got \(topLeft)")
    }

    func testLanczosUpscalePreservesAFlatColor() {
        let source = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        guard let result = SuperResolutionUpscaler.lanczosUpscale(source) else {
            return XCTFail("lanczosUpscale returned nil")
        }
        let pixel = Self.sampleColor(result, at: CGPoint(x: 20, y: 20), context: Self.testContext, colorSpace: Self.testColorSpace)
        XCTAssertEqual(pixel.0, 0.3, accuracy: 0.03)
        XCTAssertEqual(pixel.1, 0.6, accuracy: 0.03)
        XCTAssertEqual(pixel.2, 0.9, accuracy: 0.03)
    }

    func testLanczosUpscalePreservesOrientation() {
        let fixture = Self.makeAsymmetricFixture(width: 32, height: 32)
        guard let result = SuperResolutionUpscaler.lanczosUpscale(fixture) else {
            return XCTFail("lanczosUpscale returned nil")
        }
        // Red patch at x:[0,8) y:[24,32) (bottom-left-origin coordinates,
        // i.e. visually top-left) becomes roughly x:[0,16) y:[48,64) at 2x.
        let topLeft = Self.sampleColor(result, at: CGPoint(x: 4, y: 56), context: Self.testContext, colorSpace: Self.testColorSpace)
        XCTAssertGreaterThan(topLeft.0, 0.6, "expected the marked corner to read as red, got \(topLeft)")
        XCTAssertLessThan(topLeft.2, 0.4, "expected the marked corner to read as red, got \(topLeft)")
        let flipCheck = Self.sampleColor(result, at: CGPoint(x: 4, y: 8), context: Self.testContext, colorSpace: Self.testColorSpace)
        XCTAssertLessThan(flipCheck.0, 0.4, "a red reading here means lanczosUpscale flips vertically, got \(flipCheck)")
        XCTAssertGreaterThan(flipCheck.2, 0.6, "a red reading here means lanczosUpscale flips vertically, got \(flipCheck)")
    }

    // MARK: MetalFX path

    func testMetalFXUpscaleProducesExactlyDoubledExtent() throws {
        let device = try Self.requireMetalFXDevice()
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        let result = try SuperResolutionUpscaler.metalFXUpscale(source, device: device, context: Self.testContext)
        XCTAssertEqual(result.extent, CGRect(x: 0, y: 0, width: 40, height: 20))
    }

    func testMetalFXUpscalePreservesOrientation() throws {
        let device = try Self.requireMetalFXDevice()
        let fixture = Self.makeAsymmetricFixture(width: 32, height: 32)
        let result = try SuperResolutionUpscaler.metalFXUpscale(fixture, device: device, context: Self.testContext)
        let topLeft = Self.sampleColor(result, at: CGPoint(x: 4, y: 56), context: Self.testContext, colorSpace: Self.testColorSpace)
        XCTAssertGreaterThan(topLeft.0, 0.6, "expected the marked corner to read as red, got \(topLeft)")
        XCTAssertLessThan(topLeft.2, 0.4, "expected the marked corner to read as red, got \(topLeft)")
        let flipCheck = Self.sampleColor(result, at: CGPoint(x: 4, y: 8), context: Self.testContext, colorSpace: Self.testColorSpace)
        XCTAssertLessThan(flipCheck.0, 0.4, "a red reading here means metalFXUpscale flips vertically, got \(flipCheck)")
        XCTAssertGreaterThan(flipCheck.2, 0.6, "a red reading here means metalFXUpscale flips vertically, got \(flipCheck)")
    }

    func testMetalFXUpscaleReOriginsANonZeroOriginInputToExactlyDoubledExtent() throws {
        let device = try Self.requireMetalFXDevice()
        let fixture = Self.makeAsymmetricFixture(width: 32, height: 32)
            .transformed(by: CGAffineTransform(translationX: 10, y: 5))
        let result = try SuperResolutionUpscaler.metalFXUpscale(fixture, device: device, context: Self.testContext)
        // `metalFXUpscale` renders `bounds: extent` (the image's own,
        // possibly non-zero-origin extent) directly into a texture sized
        // to exactly that extent — unlike `lanczosUpscale`, there is no
        // separate crop-then-translate step to verify by hand, but the
        // OUTPUT is still expected at (0,0), since a texture has no
        // origin of its own. This is the direct MetalFX-path analog of
        // the Lanczos re-origining test above — reviewer-caught that the
        // MetalFX path had no non-zero-origin coverage at all.
        XCTAssertEqual(result.extent, CGRect(x: 0, y: 0, width: 64, height: 64))
        let topLeft = Self.sampleColor(result, at: CGPoint(x: 4, y: 56), context: Self.testContext, colorSpace: Self.testColorSpace)
        XCTAssertGreaterThan(topLeft.0, 0.6, "expected the marked corner to read as red after re-origining, got \(topLeft)")
        XCTAssertLessThan(topLeft.2, 0.4, "expected the marked corner to read as red after re-origining, got \(topLeft)")
    }

    /// Reviewer-caught, round 2, via an actual mutation (not theorized):
    /// changing `metalFXColorSpace` to `extendedLinearSRGB` — exactly the
    /// working-space-instead-of-sRGB bug this file's doc comments warn
    /// about — made every test in this file, INCLUDING this one, still
    /// pass. Root cause: `metalFXUpscale` uses the SAME constant for
    /// both the render-in step and the `CIImage(mtlTexture:options:)`
    /// readback tag, so a self-consistently-wrong constant round-trips a
    /// wrong-but-internally-consistent number with no visible difference
    /// on a FLAT color field (MetalFX is a numeric identity there,
    /// whatever the field's own values are tagged as meaning). This test
    /// therefore only confirms round-trip color FIDELITY under whatever
    /// `metalFXColorSpace` currently is — it is NOT capable of detecting
    /// that constant being wrong. `testMetalFXColorSpaceIsGammaEncodedSRGB`
    /// below is what actually pins that down, directly.
    func testMetalFXUpscalePreservesAFlatMidtoneColor() throws {
        let device = try Self.requireMetalFXDevice()
        let source = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        let result = try SuperResolutionUpscaler.metalFXUpscale(source, device: device, context: Self.testContext)
        let pixel = Self.sampleColor(result, at: CGPoint(x: 20, y: 20), context: Self.testContext, colorSpace: Self.testColorSpace)
        XCTAssertEqual(pixel.0, 0.3, accuracy: 0.03, "round-trip color fidelity drifted, got \(pixel)")
        XCTAssertEqual(pixel.1, 0.6, accuracy: 0.03, "round-trip color fidelity drifted, got \(pixel)")
        XCTAssertEqual(pixel.2, 0.9, accuracy: 0.03, "round-trip color fidelity drifted, got \(pixel)")
    }

    /// Directly pins `metalFXUpscale`'s own `colorSpace:` constant to
    /// gamma-encoded sRGB, sidestepping the blind spot the previous test's
    /// own doc comment records: a behavioral round-trip test can't
    /// distinguish this being right from it being self-consistently
    /// wrong. Confirmed (during this fix) that mutating
    /// `SuperResolutionUpscaler.metalFXColorSpace` to `extendedLinearSRGB`
    /// makes THIS assertion fail, where the behavioral test did not.
    func testMetalFXColorSpaceIsGammaEncodedSRGB() {
        XCTAssertEqual(
            SuperResolutionUpscaler.metalFXColorSpace.name as String?,
            CGColorSpace.sRGB as String,
            "metalFXUpscale's render/readback color space must be gamma-encoded sRGB, matching .perceptual mode's own documented expectation — not this project's usual extendedLinearSRGB working space"
        )
    }

    func testMetalFXUpscaleClampsHeadroomRatherThanProducingGarbage() throws {
        let device = try Self.requireMetalFXDevice()
        // A linear-light value of 1.5 is valid, in-range headroom for
        // this app's own extendedLinearSRGB working space (highlights
        // routinely exceed 1.0 before the final output clamp) but
        // out-of-contract for `.perceptual` mode's expected [0,1] input.
        // `metalFXUpscale`'s own CIColorClamp step must neutralize this,
        // not pass it through to undefined behavior.
        //
        // Reviewer-caught: sampling back through `sampleColor`'s 8-bit
        // `RGBA8` bitmap made this assertion vacuous — 8-bit readback
        // clamps to 255 on its own, so it can't tell "the CIColorClamp
        // step actually ran" apart from "nothing clamped it, but the
        // 8-bit sample format did anyway." `sampleFloatColor` reads back
        // through an unclamped, extended-range `RGBAf` bitmap instead —
        // confirmed (during this fix) that removing the `CIColorClamp`
        // step makes THIS version of the assertion fail, unlike the
        // original.
        guard let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            return XCTFail("extendedLinearSRGB color space unavailable")
        }
        guard let headroomColor = CIColor(red: 1.5, green: 1.5, blue: 1.5, alpha: 1, colorSpace: linearSpace) else {
            return XCTFail("failed to construct a headroom CIColor")
        }
        let source = CIImage(color: headroomColor).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let result = try SuperResolutionUpscaler.metalFXUpscale(source, device: device, context: Self.testContext)
        let pixel = Self.sampleFloatColor(result, at: CGPoint(x: 16, y: 16), context: Self.testContext, colorSpace: Self.testWorkingColorSpace)
        XCTAssertLessThanOrEqual(pixel.0, 1.05, "headroom should be clamped, not passed through, got \(pixel)")
        XCTAssertLessThanOrEqual(pixel.1, 1.05, "headroom should be clamped, not passed through, got \(pixel)")
        XCTAssertLessThanOrEqual(pixel.2, 1.05, "headroom should be clamped, not passed through, got \(pixel)")
    }

    func testUpscaleForcesFullOpacityConsistentlyAcrossBothMethods() throws {
        // Reviewer-caught via a real probe, not theorized: MetalFX
        // silently writes alpha=1 into its output regardless of the
        // input's own alpha, while Lanczos correctly preserves it — a
        // hardware-dependent correctness divergence `upscale` (not
        // `lanczosUpscale`/`metalFXUpscale` individually) fixes by
        // compositing over opaque black before EITHER path runs. This
        // test exercises `upscale` itself (not the two lower-level
        // functions) since that's where the fix lives, and checks BOTH
        // available methods land on the identical result.
        let device = try Self.requireMetalFXDevice()
        let transparent = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 0)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))

        guard let lanczosResult = SuperResolutionUpscaler.upscale(transparent, device: nil, context: Self.testContext) else {
            return XCTFail("upscale (Lanczos) returned nil")
        }
        XCTAssertEqual(lanczosResult.method, .lanczos)
        let lanczosPixel = Self.sampleColor(lanczosResult.image, at: CGPoint(x: 16, y: 16), context: Self.testContext, colorSpace: Self.testColorSpace)

        guard let metalFXResult = SuperResolutionUpscaler.upscale(transparent, device: device, context: Self.testContext) else {
            return XCTFail("upscale (MetalFX) returned nil")
        }
        XCTAssertEqual(metalFXResult.method, .metalFX)
        let metalFXPixel = Self.sampleColor(metalFXResult.image, at: CGPoint(x: 16, y: 16), context: Self.testContext, colorSpace: Self.testColorSpace)

        // Fully transparent input, composited over opaque black before
        // either upscale runs, must read back as opaque black through
        // BOTH methods — not just "some deterministic value," but the
        // SAME value regardless of which upscale method the local
        // hardware happens to use.
        XCTAssertEqual(lanczosPixel.3, 1.0, accuracy: 0.01, "Lanczos path: expected full opacity, got \(lanczosPixel)")
        XCTAssertEqual(metalFXPixel.3, 1.0, accuracy: 0.01, "MetalFX path: expected full opacity, got \(metalFXPixel)")
        XCTAssertEqual(lanczosPixel.0, metalFXPixel.0, accuracy: 0.02, "the two methods disagree on a transparent region's resolved color: \(lanczosPixel) vs \(metalFXPixel)")
        XCTAssertEqual(lanczosPixel.1, metalFXPixel.1, accuracy: 0.02, "the two methods disagree on a transparent region's resolved color: \(lanczosPixel) vs \(metalFXPixel)")
        XCTAssertEqual(lanczosPixel.2, metalFXPixel.2, accuracy: 0.02, "the two methods disagree on a transparent region's resolved color: \(lanczosPixel) vs \(metalFXPixel)")
    }

    func testUpscalePicksMetalFXWhenAvailable() throws {
        let device = try Self.requireMetalFXDevice()
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let result = SuperResolutionUpscaler.upscale(source, device: device, context: Self.testContext) else {
            return XCTFail("upscale returned nil")
        }
        XCTAssertEqual(result.method, .metalFX)
        XCTAssertNil(result.fallbackReason)
    }

    // MARK: Forced fallback

    func testUpscaleFallsBackToLanczosWithNoDevice() {
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        guard let result = SuperResolutionUpscaler.upscale(source, device: nil, context: Self.testContext) else {
            return XCTFail("upscale returned nil")
        }
        XCTAssertEqual(result.method, .lanczos)
        XCTAssertEqual(result.fallbackReason, .noMetalDevice)
        XCTAssertEqual(result.image.extent, CGRect(x: 0, y: 0, width: 40, height: 20))
    }

    func testUpscaleReturnsNilForADegenerateExtent() {
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: .infinite)
        XCTAssertNil(SuperResolutionUpscaler.upscale(source, device: nil, context: Self.testContext))
    }

    // MARK: Shared fixtures

    private static let testColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let testWorkingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? testColorSpace
    private static let testContext = CIContext(options: [.workingColorSpace: testWorkingColorSpace])

    /// Renders `image` to an UNCLAMPED, extended-range `RGBAf` bitmap and
    /// reads back one pixel — unlike `sampleColor`'s 8-bit `RGBA8`
    /// readback (which clamps to [0,1] on its own regardless of whether
    /// anything upstream already clamped it), this can actually tell
    /// "the value is at or below 1.0" apart from "the value is above 1.0
    /// but the READBACK format clipped it anyway" — reviewer-caught: the
    /// original headroom test used `sampleColor` and passed vacuously
    /// even with `metalFXUpscale`'s own `CIColorClamp` step removed.
    private static func sampleFloatColor(_ image: CIImage, at point: CGPoint, context: CIContext, colorSpace: CGColorSpace) -> (Double, Double, Double, Double) {
        var pixel = [Float](repeating: 0, count: 4)
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(
                image, toBitmap: buffer.baseAddress!, rowBytes: 16, bounds: rect,
                format: .RGBAf, colorSpace: colorSpace
            )
        }
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]), Double(pixel[3]))
    }

    private static func requireMetalFXDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine.")
        }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            throw XCTSkip("\(device.name) does not support MetalFX spatial scaling.")
        }
        return device
    }

    /// Same red/blue asymmetric layout as `testMetalFXSpatialScalerProbe`'s
    /// own fixture, generalized to an arbitrary size: red in one specific
    /// corner (bottom-left-origin coordinates, so visually top-left), blue
    /// everywhere else — enough to catch a vertical flip, a horizontal
    /// flip, a 180° rotation, or a transpose, all at once.
    private static func makeAsymmetricFixture(width: Int, height: Int) -> CIImage {
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let redPatch = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: height - 8, width: 8, height: 8))
        return redPatch.composited(over: blue)
    }
}
