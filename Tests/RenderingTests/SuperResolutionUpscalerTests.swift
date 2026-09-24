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
