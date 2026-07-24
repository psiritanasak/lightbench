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
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    var image: CIImage?
    var editState: EditState = .identity

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
        let fitRect = AspectFit.rect(fitting: edited.extent.size, in: drawableSize)
        guard fitRect.width > 0, fitRect.height > 0 else { return }

        // No manual y-flip here. Empirically verified against this exact live
        // on-screen MTKView (colorPixelFormat = .rgba16Float, framebufferOnly =
        // false — see MetalImageView.swift) with a real photo (EXIF orientation
        // 1/identity): adding a y-flip made the on-screen result appear rotated
        // 180°; removing it displays correctly. The exact mechanism isn't fully
        // understood — an earlier version added the flip because it tested
        // "correct" against an offline, manually-created MTLTexture read back on
        // the CPU, so something about that offscreen setup doesn't faithfully
        // reproduce this live drawable's behavior. Do NOT assume "no flip" holds
        // for other destinations or configs — in particular, Phase 5 batch
        // export and Phase 7 tiled rendering will render to offscreen/standalone
        // MTLTextures (the same shape of destination that misled the earlier
        // test), so that path must be independently re-derived and verified
        // against real output when it's built, not assumed identical to this.
        let scale = fitRect.width / edited.extent.width
        let transform = CGAffineTransform(translationX: -edited.extent.minX, y: -edited.extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: fitRect.minX, y: fitRect.minY))
        let fittedImage = edited.transformed(by: transform)

        ciContext.render(
            fittedImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: drawableSize),
            colorSpace: outputColorSpace
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
