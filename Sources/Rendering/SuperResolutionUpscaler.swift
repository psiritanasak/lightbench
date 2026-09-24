import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import MetalFX

/// Upscales a rendered `CIImage` 2x for the Enhance/Super Resolution
/// feature (`PhotoEnhancer`), preferring Apple's on-device MetalFX
/// spatial upscaler with a graceful, always-available Lanczos fallback —
/// mirroring `PhotoExporter`'s own existing "Metal device unavailable ->
/// plain CIContext" degrade pattern. See
/// `Tests/RenderingTests/SuperResolutionUpscalerTests.swift`'s own
/// `testMetalFXSpatialScalerProbe` for the real, run measurement that
/// justified choosing MetalFX over Lanczos-only for v1 — PROGRESS.md has
/// the numbers (a synthetic 6016x4016 -> 12032x8032 upscale, matching the
/// D610's own RAW dimensions, completed end to end in 0.454s on this
/// project's dev machine).
///
/// Callers (`PhotoEnhancer`) MUST NOT call `upscale`/`metalFXUpscale` on
/// the main thread — `metalFXUpscale` blocks on `waitUntilCompleted()` —
/// and, for a RAW source, MUST route the call through
/// `RawDecoder.RenderGate`, exactly like `PhotoExporter.export`/
/// `ProxyBuilder.build` already do: unlike the Lanczos path (which stays
/// a lazy `CIImage` graph until something downstream renders it),
/// `metalFXUpscale` eagerly renders the whole upstream graph right here,
/// which for a RAW source means this IS the first real render of the
/// lazy `CIRAWFilter` graph — exactly the situation `RenderGate` exists
/// to serialize app-wide. `context` must be a Metal-backed `CIContext`
/// built on the SAME `MTLDevice` passed as `device` — a mismatched
/// device (possible on dual-GPU Intel Macs, or if a non-Metal fallback
/// `CIContext` is passed) is a caller error, not something this type
/// detects or corrects.
enum SuperResolutionUpscaler {
    static let scaleFactor = 2

    /// Metal's documented max 2D texture dimension on Apple-silicon/Mac2
    /// GPU families — confirmed empirically by this feature's own probe,
    /// which allocated a 12032x8032 output texture (a real D610 RAW
    /// frame's dimensions x2) without issue, comfortably under this
    /// limit. Core Image's own Lanczos path has no such limit (it tiles
    /// internally), which is exactly why `plannedMethod` falls back to
    /// it rather than failing outright above this size.
    static let maxTextureDimension = 16384

    enum Method: Equatable, Sendable {
        case metalFX
        case lanczos
    }

    enum FallbackReason: Equatable, Sendable, Error {
        case noMetalDevice
        case deviceUnsupported
        case exceedsMaxTextureSize
        case scalerConstructionFailed
        case textureAllocationFailed
        case encodeFailed(String)
    }

    /// Named to avoid shadowing `Swift.Result` inside this enum's own
    /// scope — the same hazard class `PhotoCollection` (not `Collection`)
    /// already avoids elsewhere in this codebase.
    struct UpscaleResult: Sendable {
        let image: CIImage
        let method: Method
        let fallbackReason: FallbackReason?
    }

    /// `extent` scaled by `scaleFactor`, guarded against the same
    /// degenerate-extent hazards `ProxyBuilder.build`/`RawDecoder
    /// .materialize` already guard against — `CGRect.infinite`'s
    /// width/height are finite by IEEE semantics, so `.isFinite` alone
    /// would not catch it; `.isInfinite` is the correct check, the same
    /// trap those two functions' own guards already record. The upper
    /// bound (`Int32.max / scaleFactor`, not just `Int32.max`) matters
    /// beyond documenting intent: without it, `extent.width * scaleFactor`
    /// could itself exceed `Int32.max` and make the later `Int(_:)`
    /// conversion produce a nonsensical (though not trapping, since the
    /// destination is `Int` not `Int32`) huge value.
    ///
    /// Rounds `extent.width`/`height` to integers FIRST, then multiplies
    /// by `scaleFactor` — not the other way around (round(width) *
    /// scaleFactor, not round(width * scaleFactor)) — reviewer-caught:
    /// for a fractional extent (a crop can produce one), rounding the
    /// pre-scaled width independently of the input pixel dimensions
    /// `metalFXUpscale` actually allocates would drift the output out of
    /// an EXACT 2x relationship to the input texture it was actually
    /// built from.
    static func outputPixelSize(for extent: CGRect) -> (width: Int, height: Int)? {
        guard let (inputWidth, inputHeight) = inputPixelSize(for: extent) else { return nil }
        return (inputWidth * scaleFactor, inputHeight * scaleFactor)
    }

    /// The integer pixel size `metalFXUpscale`'s input texture is
    /// actually allocated at — `outputPixelSize` derives FROM this, not
    /// independently, so the two can never drift apart (see that
    /// function's own doc comment for why that matters).
    private static func inputPixelSize(for extent: CGRect) -> (width: Int, height: Int)? {
        guard !extent.isInfinite, !extent.isNull,
              extent.width > 0, extent.height > 0,
              extent.width < CGFloat(Int32.max) / CGFloat(scaleFactor),
              extent.height < CGFloat(Int32.max) / CGFloat(scaleFactor)
        else {
            return nil
        }
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Decides which method `upscale` should attempt, and why, BEFORE any
    /// rendering happens — pure and directly testable, so the fallback
    /// logic doesn't require a real `MTLDevice`/`CIContext` to verify.
    static func plannedMethod(
        outputWidth: Int, outputHeight: Int, hasDevice: Bool, deviceSupportsMetalFX: Bool
    ) -> (Method, FallbackReason?) {
        guard hasDevice else { return (.lanczos, .noMetalDevice) }
        guard deviceSupportsMetalFX else { return (.lanczos, .deviceUnsupported) }
        guard outputWidth <= maxTextureDimension, outputHeight <= maxTextureDimension else {
            return (.lanczos, .exceedsMaxTextureSize)
        }
        return (.metalFX, nil)
    }

    /// The single entry point `PhotoEnhancer` calls. Never throws — a
    /// MetalFX failure at any stage (construction or encode) falls back
    /// to Lanczos rather than failing the whole Enhance operation, since
    /// Lanczos is unconditionally available. Returns `nil` only if the
    /// image's own extent is degenerate (see `outputPixelSize`) or the
    /// Lanczos fallback itself fails (a `CIFilter` failure — not expected
    /// in practice, but never force-unwrapped).
    static func upscale(_ image: CIImage, device: MTLDevice?, context: CIContext) -> UpscaleResult? {
        guard let (outputWidth, outputHeight) = outputPixelSize(for: image.extent) else { return nil }

        // Force full opacity BEFORE either upscale path runs —
        // reviewer-caught via a real probe (not theorized): MetalFX
        // silently writes alpha=1 into its output texture regardless of
        // the input's own alpha, while Lanczos correctly preserves
        // partial/zero alpha. That's a hardware-dependent correctness
        // divergence for any edit with a visible transparent margin
        // (e.g. `transformScale` < 1 composited over a transparent
        // canvas, per `EditPipeline.applyTransformScale`'s own doc
        // comment, with no crop removing the margin). Since Enhance's
        // v1 output is ALWAYS JPEG (no alpha channel at all — see
        // `PhotoEnhancer`), a transparent region was always going to
        // resolve to SOME opaque color at write time regardless of
        // upscale method; compositing over black HERE, uniformly, makes
        // both paths behave identically (and matches what the same edit
        // already produces via ordinary JPEG export) instead of
        // depending on which upscale method the local hardware happens
        // to use. A no-op, cost-free graph node for the overwhelmingly
        // common already-fully-opaque case.
        let opaqueBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: image.extent)
        let opaqueImage = image.composited(over: opaqueBackground)

        let deviceSupportsMetalFX = device.map { MTLFXSpatialScalerDescriptor.supportsDevice($0) } ?? false
        let (method, reason) = plannedMethod(
            outputWidth: outputWidth, outputHeight: outputHeight,
            hasDevice: device != nil, deviceSupportsMetalFX: deviceSupportsMetalFX
        )

        if method == .metalFX, let device {
            do {
                let scaled = try metalFXUpscale(opaqueImage, device: device, context: context)
                return UpscaleResult(image: scaled, method: .metalFX, fallbackReason: nil)
            } catch let reason as FallbackReason {
                guard let fallback = lanczosUpscale(opaqueImage) else { return nil }
                return UpscaleResult(image: fallback, method: .lanczos, fallbackReason: reason)
            } catch {
                guard let fallback = lanczosUpscale(opaqueImage) else { return nil }
                return UpscaleResult(image: fallback, method: .lanczos, fallbackReason: .encodeFailed(error.localizedDescription))
            }
        }

        guard let fallback = lanczosUpscale(opaqueImage) else { return nil }
        return UpscaleResult(image: fallback, method: .lanczos, fallbackReason: reason)
    }

    /// Plain Lanczos 2x upscale — the sibling, mirror-image operation to
    /// `ProxyBuilder.build`'s own downscale (`scale <= 1` there, a fixed
    /// `scaleFactor` of 2 here), NOT a reuse of that type: `ProxyBuilder`'s
    /// whole contract is "downscale into a realized `CVPixelBuffer` for
    /// the live interactive proxy pipeline," a different concern from
    /// this one-shot, full-resolution upscale that stays a lazy `CIImage`
    /// graph until `PhotoExporter.write` renders it. Same
    /// `.clampedToExtent()` edge-darkening precaution `ProxyBuilder` uses,
    /// same crop-then-translate technique for handling a non-zero-origin
    /// input (a crop can leave one) so the result is always an exact
    /// `(0, 0, 2w, 2h)` rect regardless of the input's own origin.
    static func lanczosUpscale(_ image: CIImage) -> CIImage? {
        let extent = image.extent
        guard let (pixelWidth, pixelHeight) = outputPixelSize(for: extent) else { return nil }

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scaleFactor)
        filter.aspectRatio = 1
        guard let scaledUnclamped = filter.outputImage else { return nil }

        let scaledOrigin = CGPoint(x: extent.minX * CGFloat(scaleFactor), y: extent.minY * CGFloat(scaleFactor))
        let sourceRect = CGRect(
            x: scaledOrigin.x, y: scaledOrigin.y,
            width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)
        )
        return scaledUnclamped
            .cropped(to: sourceRect)
            .transformed(by: CGAffineTransform(translationX: -scaledOrigin.x, y: -scaledOrigin.y))
    }

    /// The color space MetalFX's `.perceptual` mode expects: gamma-encoded
    /// sRGB, NOT this project's usual `extendedLinearSRGB` working space
    /// (`SuperResolutionUpscalerTests.swift`'s own probe doc comment has
    /// the full reasoning — reviewer-caught before any production code
    /// existed to get it wrong first). What makes `.perceptual` correct
    /// here is passing THIS as the `colorSpace:` argument to BOTH the
    /// render into the input texture AND the `CIImage(mtlTexture:options:)`
    /// readback tag below — that argument converts to this space AS it
    /// writes into the destination texture, independent of the context's
    /// own working space (the same mechanism `PhotoExporter.write`'s
    /// `colorSpace: outputColorSpace` argument already uses for its
    /// JPEG/PNG/TIFF writers).
    ///
    /// Not `private`: `SuperResolutionUpscalerTests` asserts this
    /// constant's identity directly (reviewer-caught, round 2 — a
    /// behavioral round-trip test using a FLAT color field can't actually
    /// distinguish this being set correctly from both the render-in and
    /// read-out steps using the SAME wrong value self-consistently: on a
    /// flat field MetalFX is a numeric identity, so a self-consistent
    /// wrong tag round-trips a wrong-but-internally-consistent number
    /// with no observable difference at the test's own readback). Same
    /// testability-motivated visibility widening as `ProxyBuilder
    /// .colorSpace`/`RawDecoder.materializeColorSpace`.
    static let metalFXColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Renders `image` into a private `MTLTexture`, runs
    /// `MTLFXSpatialScaler` on it, and reads the result back as a
    /// `CIImage` — throws `FallbackReason` on any failure so `upscale`
    /// can fall back to Lanczos rather than losing the whole Enhance
    /// operation. See this feature's own probe test for the reasoning
    /// behind every choice here (color processing mode, texture usage
    /// flags, why no orientation fix-up is applied). See this type's own
    /// doc comment for the main-thread/`RenderGate`/device-matching
    /// preconditions callers must uphold.
    static func metalFXUpscale(_ image: CIImage, device: MTLDevice, context: CIContext) throws -> CIImage {
        let extent = image.extent
        guard let (inputWidth, inputHeight) = inputPixelSize(for: extent) else {
            throw FallbackReason.scalerConstructionFailed
        }
        let outputWidth = inputWidth * scaleFactor
        let outputHeight = inputHeight * scaleFactor

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.outputTextureFormat = .rgba16Float
        // Perceptual mode expects clamped [0,1] gamma-encoded values —
        // see `metalFXColorSpace`'s own doc comment. `.linear`/`.hdr`
        // would need unclamped scene-linear data instead, which this
        // app's output pipeline (always sRGB SDR at write time, per
        // `PhotoExporter.outputColorSpace`) never needs.
        descriptor.colorProcessingMode = .perceptual

        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            throw FallbackReason.scalerConstructionFailed
        }

        // Usage flags union what the SCALER itself declares it needs
        // with what CORE IMAGE separately needs for its own half of the
        // round trip — the probe test's own doc comment records a real,
        // self-caught regression where trusting the scaler's declared
        // usage ALONE made Core Image's render fail silently (no thrown
        // error; every sample read back as flat black). A `nil` texture
        // here (distinct from scaler construction) is almost certainly
        // an out-of-memory condition — the output texture alone is
        // ~773MB at the D610's own full-res dimensions x2 — so it gets
        // its own, more specific `FallbackReason` rather than being
        // folded into `.scalerConstructionFailed`.
        guard
            let inputTexture = Self.makeTexture(
                device: device, width: inputWidth, height: inputHeight,
                usage: scaler.colorTextureUsage.union([.shaderWrite, .renderTarget])
            ),
            let outputTexture = Self.makeTexture(
                device: device, width: outputWidth, height: outputHeight,
                usage: scaler.outputTextureUsage.union([.shaderRead])
            )
        else {
            throw FallbackReason.textureAllocationFailed
        }

        guard let commandQueue = device.makeCommandQueue(), let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw FallbackReason.encodeFailed("failed to create a Metal command buffer")
        }

        // Perceptual mode expects values clamped to [0,1] — the working
        // space has extended-range headroom (highlights can exceed 1.0
        // before the final output clamp), and an unclamped value fed to
        // `.perceptual` is out-of-contract, not documented Apple
        // behavior. Measured (this feature's own tests, verified to
        // actually fail without this step): on this machine MetalFX does
        // NOT produce garbage for an unclamped value — 1.5 linear passed
        // through as ~1.492, essentially unchanged, not corrupted — but
        // that's this hardware's observed behavior today, not a
        // documented contract to rely on. This clamp keeps the input
        // within the mode's own stated domain regardless.
        let clampFilter = CIFilter.colorClamp()
        clampFilter.inputImage = image
        clampFilter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampFilter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let clamped = clampFilter.outputImage else {
            throw FallbackReason.encodeFailed("CIColorClamp failed")
        }

        context.render(
            clamped, to: inputTexture, commandBuffer: commandBuffer,
            bounds: extent, colorSpace: metalFXColorSpace
        )

        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            throw FallbackReason.encodeFailed(commandBuffer.error?.localizedDescription ?? "status \(commandBuffer.status.rawValue)")
        }

        guard let result = CIImage(mtlTexture: outputTexture, options: [.colorSpace: metalFXColorSpace]) else {
            throw FallbackReason.encodeFailed("CIImage(mtlTexture:) returned nil")
        }

        // `context` is caller-owned (`PhotoExporter.context`, a
        // long-lived static) and this render is at full photo
        // resolution — without clearing, its internal intermediate
        // caches hold onto this render's working buffers indefinitely,
        // same rationale as `ProxyBuilder.build`'s own `clearCaches()`
        // call (reviewer-measured there: ~284MB retained across 8
        // successive builds without it).
        context.clearCaches()

        // No orientation fix-up (e.g. `.oriented(.downMirrored)`) — this
        // feature's own probe test confirmed, on real hardware, that the
        // render round trip does NOT flip vertically. Not assumed — see
        // `PhotoExporter`'s own doc comment on why an offscreen-texture
        // path's orientation must always be independently verified.
        return result
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}
