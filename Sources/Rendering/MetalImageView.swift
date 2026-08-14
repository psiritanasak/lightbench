import MetalKit
import SwiftUI

/// Displays a `CIImage` in a Metal-backed view, aspect-fit and centered.
struct MetalImageView: NSViewRepresentable {
    var image: CIImage?
    var editState: EditState
    /// Non-nil enables the Compare feature. See `ImageRenderer.compare`.
    var compare: CompareRenderConfig?

    func makeNSView(context: Context) -> MTKView {
        let renderer = context.coordinator
        let view = ResizingMTKView(frame: .zero, device: renderer.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .rgba16Float
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = renderer
        // Tag the presenting layer with the SAME color space
        // `ImageRenderer.draw(in:)` encodes its final render into
        // (`outputColorSpace`, sRGB). MTKView is layer-backed by a
        // `CAMetalLayer` from init, so it's available here. Without this,
        // the sRGB-gamma-encoded float values written into this
        // `.rgba16Float` drawable are presented untagged — CoreAnimation
        // doesn't decode them as sRGB, so the Editor renders visibly
        // brighter/less saturated than Preview.app or this app's own
        // exported files (which ARE correctly sRGB-tagged via
        // `CIContext.write*Representation(colorSpace:)`) despite identical
        // color-space math in both paths — a real, live-verified bug, not
        // a hypothetical.
        let metalLayer = view.layer as? CAMetalLayer
        assert(metalLayer != nil, "MTKView's backing layer was expected to be a CAMetalLayer")
        metalLayer?.colorspace = renderer.outputColorSpace
        return view
    }

    /// Skips the redraw entirely when neither `image` nor `editState` (nor,
    /// now, `compare`) actually changed since the last call. SwiftUI
    /// re-invokes `updateNSView` on any observed document change, but during
    /// an interactive crop drag the image shown here (`ContentView`'s
    /// `displayEditState`, with crop insets zeroed) is intentionally held
    /// constant while only the crop overlay moves — this guard keeps those
    /// frames free of redundant Core Image pipeline re-runs. `image` is
    /// compared by reference (`currentImage` is only ever reassigned
    /// wholesale on load, never mutated in place); `editState`/`compare` by
    /// value (`Equatable`) — `compare` must be included here or dragging the
    /// Compare divider (which only changes `compare.mode`'s `position`,
    /// nothing else) would never trigger a redraw.
    func updateNSView(_ nsView: MTKView, context: Context) {
        let renderer = context.coordinator
        guard image !== renderer.image || editState != renderer.editState || compare != renderer.compare else {
            return
        }
        renderer.image = image
        renderer.editState = editState
        renderer.compare = compare
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> ImageRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        return ImageRenderer(device: device)
    }
}

/// MTKView redraws on `setNeedsDisplay` only (no run loop); this subclass
/// requests a redraw on resize so the image stays correctly fitted.
private final class ResizingMTKView: MTKView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsDisplay(bounds)
    }

    /// Explicitly opt OUT of intrinsic sizing — this view should always be
    /// sized purely by whatever frame its SwiftUI parent (`GeometryReader`
    /// inside the HSplitView pane) gives it, never by its own content.
    /// Candidate fix for a live-observed bug: opening the FIRST photo after
    /// launch (and only the first — later photos don't repeat it) narrows
    /// the sidebar/widens the image pane by a small amount, suggesting
    /// `HSplitView`'s one-time initial divide computation picks up SOME
    /// content-dependent sizing signal from this view once it first has a
    /// real drawable/texture, differing from its signal while empty.
    /// `MTKView`'s own default `intrinsicContentSize` behavior isn't
    /// documented as content-independent, so this removes the ambiguity
    /// outright rather than guessing at a magic frame size to compensate.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
