import CoreImage
import MetalKit

/// Renders a `CIImage` into an `MTKView`'s drawable, aspect-fit and centered.
///
/// `draw(in:)` is only ever invoked by MetalKit on the main thread (the view
/// is configured with `isPaused = true` / `enableSetNeedsDisplay = true`, so
/// there is no internal render loop), and `image` is only ever written from
/// `MetalImageView.updateNSView`, which SwiftUI also calls on the main actor.
/// Marking the type `@MainActor` makes that contract explicit instead of implicit.
@MainActor
final class ImageRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    /// Core Image performs all filter math (via `EditPipeline`) in this
    /// explicitly-defined linear working space (extended-range linear sRGB,
    /// 16-bit half-float to match the view's `.rgba16Float` drawable). This
    /// satisfies CLAUDE.md's "all image math in linear light in a defined
    /// working color space" — the space is defined here rather than relying
    /// on CIContext's defaults. Extended range preserves highlight/shadow
    /// headroom created by adjustments like exposure. Conversion to display
    /// sRGB happens only at final render, via `outputColorSpace` below (the
    /// "output transform" stage of the fixed pipeline).
    private let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        ?? CGColorSpace(name: CGColorSpace.linearSRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    /// Not `private`: `MetalImageView.makeNSView` tags the presenting
    /// `CAMetalLayer` with this SAME instance, so the drawable's declared
    /// color space can never drift from what `render(...)` below actually
    /// encodes into. Without that layer tag, CoreAnimation doesn't know
    /// this `.rgba16Float` drawable's sRGB-gamma-encoded values are sRGB
    /// (float formats have no `_sRGB` pixel-format variant to imply it),
    /// so it under-decodes them on display — a real, live-verified bug:
    /// the Editor rendered visibly brighter/less saturated than the same
    /// file in Preview.app or this app's own (correctly-tagged) exported
    /// files, despite identical working/output color-space math in both
    /// paths.
    let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    var image: CIImage?
    var editState: EditState = .identity
    /// Non-nil enables the Compare feature (Side by Side / Split);
    /// `nil` is the default, single-image path — see `draw(in:)`.
    var compare: CompareRenderConfig?

    init(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else {
            fatalError("Metal device failed to create a command queue")
        }
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingColorSpace,
            .workingFormat: CIFormat.RGBAh
        ])
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Scales/translates `image` to occupy exactly `fitRect` — the SAME
    /// arithmetic `draw(in:)` always used inline, extracted (not
    /// rewritten) so the Compare feature's extra fitted images go through
    /// the identical math as the single-image path, byte for byte. See
    /// `draw(in:)`'s own comment for why there's deliberately no y-flip
    /// here.
    private func fitted(_ image: CIImage, into fitRect: CGRect) -> CIImage {
        let scale = fitRect.width / image.extent.width
        let transform = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: fitRect.minX, y: fitRect.minY))
        return image.transformed(by: transform)
    }

    func draw(in view: MTKView) {
        guard let image,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // MARK: - Edit pipeline
        let edited = EditPipeline.apply(editState, to: image)

        // Fit/transform against `edited.extent`, not `image.extent`: exposure
        // doesn't change extent so this is a no-op today, but the future crop
        // stage will change extent, so this must stay `edited` — don't
        // "simplify" it back to `image`.
        let drawableSize = view.drawableSize

        // No manual y-flip anywhere in this file. Empirically verified against
        // this exact live on-screen MTKView (colorPixelFormat = .rgba16Float,
        // framebufferOnly = false — see MetalImageView.swift) with a real photo
        // (EXIF orientation 1/identity): adding a y-flip made the on-screen
        // result appear rotated 180°; removing it displays correctly. The exact
        // mechanism isn't fully understood — an earlier version added the flip
        // because it tested "correct" against an offline, manually-created
        // MTLTexture read back on the CPU, so something about that offscreen
        // setup doesn't faithfully reproduce this live drawable's behavior. Do
        // NOT assume "no flip" holds for other destinations or configs — in
        // particular, Phase 5 batch export and Phase 7 tiled rendering render to
        // offscreen/standalone MTLTextures (the same shape of destination that
        // misled the earlier test), so those paths were independently
        // re-derived and verified, not assumed identical to this. The Compare
        // feature's horizontal-split orientation has the SAME open question —
        // which drawable-space half is visually "top" — and MUST be verified
        // live on a real photo (see `splitRects`' call site below), not
        // assumed from the geometry alone.

        // Composite over an explicit full-bounds black background before
        // rendering. Without this, CIContext.render only guarantees pixels
        // within the fitted image's own footprint — before crop existed, the
        // fitted image always touched at least one full edge of the
        // drawable (AspectFit always scales to fill one dimension), so the
        // untouched-margin case was never really exercised. Crop is the
        // first stage that can shrink the fitted image well below the
        // drawable's size on BOTH axes at once (e.g. a narrow, tall crop
        // fit into a wide window), leaving large margins. MTKView cycles
        // through multiple buffered drawable textures across frames; without
        // this explicit clear, dragging a crop slider left stale content
        // from earlier frames visible in those margins (looked like tiled/
        // repeated copies of the image) because each buffer in rotation
        // only ever had its own footprint overwritten, never the margins
        // around it.
        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: drawableSize))

        let composited: CIImage
        if let compare {
            // `original`'s geometry (crop/straighten/perspective/flip) is
            // identical to `edited`'s by construction — `comparisonOriginal()`
            // only resets color/tone fields — so `original.extent ==
            // edited.extent` always holds, and both sides can share ONE
            // `fitRect`/`AspectFit` computation below.
            let original = EditPipeline.apply(compare.originalState, to: image)
            switch compare.mode {
            case .sideBySide:
                let (leftRect, rightRect) = CompareLayout.sideBySideFitRects(
                    imageSize: edited.extent.size, drawableSize: drawableSize
                )
                guard leftRect.width > 0, leftRect.height > 0 else { return }
                // Original on the left, edited on the right — fixed layout,
                // matching the confirmed design (no orientation choice for
                // Side by Side).
                let fittedOriginal = fitted(original, into: leftRect)
                let fittedEdited = fitted(edited, into: rightRect)
                composited = fittedOriginal.composited(over: fittedEdited.composited(over: background))
            case .split(let orientation, let position):
                let fitRect = AspectFit.rect(fitting: edited.extent.size, in: drawableSize)
                guard fitRect.width > 0, fitRect.height > 0 else { return }
                let fittedEdited = fitted(edited, into: fitRect)
                let fittedOriginal = fitted(original, into: fitRect)
                // `CompareDividerOverlay` measures `position` in SwiftUI's
                // top-down space (0 = visual top, matching `fitRect.minY`
                // there). THIS fitRect is in Core Image's bottom-up space,
                // where `minY` is the visual BOTTOM — the same convention
                // this file's documented "no y-flip" finding establishes —
                // the OPPOSITE of the overlay's, for the y axis specifically.
                // The x axis has no such inversion (confirmed live: Side by
                // Side's fixed left/right layout matches expectations with
                // no adjustment). So for `.vertical`, `position`/`.first`
                // are used as-is; for `.horizontal`, the position fed into
                // `splitRects` is inverted, and `.second` (not `.first`) is
                // what actually lands in the visually-above-the-line region
                // the overlay draws — MEASURED LIVE, not assumed: the
                // pre-fix version put the rendered seam nowhere near the
                // drawn line, and dragging moved the edited region in the
                // visually opposite direction from the cursor.
                let originalRegion: CGRect
                switch orientation {
                case .vertical:
                    originalRegion = CompareLayout.splitRects(fitRect, orientation: .vertical, position: position).first
                case .horizontal:
                    originalRegion = CompareLayout.splitRects(fitRect, orientation: .horizontal, position: 1 - position).second
                }
                composited = fittedOriginal.cropped(to: originalRegion)
                    .composited(over: fittedEdited.composited(over: background))
            }
        } else {
            let fitRect = AspectFit.rect(fitting: edited.extent.size, in: drawableSize)
            guard fitRect.width > 0, fitRect.height > 0 else { return }
            composited = fitted(edited, into: fitRect).composited(over: background)
        }

        ciContext.render(
            composited,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: drawableSize),
            colorSpace: outputColorSpace
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
