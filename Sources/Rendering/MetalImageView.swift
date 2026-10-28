import MetalKit
import SwiftUI

/// Displays a `CIImage` in a Metal-backed view, aspect-fit and centered.
struct MetalImageView: NSViewRepresentable {
    var image: CIImage?
    var editState: EditState
    /// Non-nil enables the Compare feature. See `ImageRenderer.compare`.
    var compare: CompareRenderConfig?
    /// See `ImageRenderer.zoomScale`/`panOffset`.
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
    /// Whether scroll-to-zoom is currently armed — mirrors `ContentView.
    /// canZoom` (false during crop-editing/WB-picking/red-eye-placement).
    var zoomEnabled: Bool = false
    /// Fired by `ResizingMTKView`'s scroll monitor with a y-DOWN,
    /// view-bounds-normalized cursor fraction and the raw scroll delta.
    /// `ContentView` owns turning this into an actual zoom/pan update
    /// (it needs to know which fit rect — single-image vs. a Side-by-Side
    /// half — the cursor fraction should be interpreted against).
    var onScrollZoom: ((CGPoint, CGFloat) -> Void)?

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
        // D82: the renderer is reached through a weak capture, so the view -> watchdog -> closure chain holds no cycle.
        view.drawCount = { [weak renderer] in renderer?.drawCount ?? 0 }
        renderer.onInternalRedraw = { [weak view] in view?.watchdog.requested() }
        return view
    }

    /// Skips the redraw entirely when nothing that actually affects the
    /// render changed since the last call. SwiftUI re-invokes
    /// `updateNSView` on any observed document change, but during an
    /// interactive crop drag the image shown here (`ContentView`'s
    /// `displayEditState`, with crop insets zeroed) is intentionally held
    /// constant while only the crop overlay moves — this guard keeps
    /// those frames free of redundant Core Image pipeline re-runs.
    /// `image` is compared by reference (`currentImage` is only ever
    /// reassigned wholesale on load, never mutated in place); the rest by
    /// value (`Equatable`) — EVERY one of these must be included, or the
    /// corresponding interaction silently stops redrawing mid-gesture
    /// (already learned once for `compare`: dragging the Compare divider
    /// only changes `compare.mode`'s `position`, nothing else the guard
    /// was watching; the same risk applies to `zoomScale`/`panOffset`
    /// changing during a scroll/pan).
    func updateNSView(_ nsView: MTKView, context: Context) {
        let renderer = context.coordinator
        guard image !== renderer.image || editState != renderer.editState || compare != renderer.compare
            || zoomScale != renderer.zoomScale || panOffset != renderer.panOffset
        else {
            (nsView as? ResizingMTKView)?.onScrollZoom = onScrollZoom
            (nsView as? ResizingMTKView)?.zoomEnabled = zoomEnabled
            return
        }
        renderer.image = image
        renderer.editState = editState
        renderer.compare = compare
        renderer.zoomScale = zoomScale
        renderer.panOffset = panOffset
        (nsView as? ResizingMTKView)?.onScrollZoom = onScrollZoom
        (nsView as? ResizingMTKView)?.zoomEnabled = zoomEnabled
        nsView.setNeedsDisplay(nsView.bounds)
        (nsView as? ResizingMTKView)?.watchdog.requested()
    }

    func makeCoordinator() -> ImageRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        return ImageRenderer(device: device)
    }
}

/// MTKView redraws on `setNeedsDisplay` only (no run loop); this subclass
/// requests a redraw on resize so the image stays correctly fitted, and
/// owns capturing scroll-wheel input for the zoom feature.
private final class ResizingMTKView: MTKView {
    /// Set (every `updateNSView` call) from `MetalImageView.onScrollZoom`.
    var onScrollZoom: ((CGPoint, CGFloat) -> Void)?
    /// Set from `MetalImageView.zoomEnabled` — mirrors `ContentView.
    /// canZoom`.
    var zoomEnabled: Bool = false

    /// `nonisolated(unsafe)`: `deinit` is always `nonisolated` in Swift
    /// (deallocation isn't tied to any actor), so it can't touch a plain
    /// `@MainActor`-inferred stored property — but this token is just an
    /// opaque, safely-nilable reference with no real concurrency hazard;
    /// `deinit` runs exactly once, with no concurrent access possible.
    /// This is the standard, accepted pattern for tearing down an
    /// `NSEvent` monitor (or similar legacy-API handle) from `deinit`.
    nonisolated(unsafe) private var scrollMonitor: Any?

    /// Set in `makeNSView`: the renderer's draw counter (see `DrawWatchdog`).
    var drawCount: () -> Int = { 0 }

    /// D82: forces a draw when a requested redraw never happens. Only fires while the view is in a visible window.
    private(set) lazy var watchdog = DrawWatchdog(
        drawCount: { [weak self] in self?.drawCount() ?? 0 },
        canDraw: { [weak self] in
            guard let window = self?.window else { return false }
            // Deliberately NOT the window occlusion visible bit: in the failing launch it read 8192 (no .visible bit) while the
            // window was on screen, and forcing a draw worked.
            guard let self else { return false }
            return window.isVisible && !window.isMiniaturized && !self.isHiddenOrHasHiddenAncestor
                && self.bounds.width > 0 && self.bounds.height > 0
        },
        forceDraw: { [weak self] in self?.draw() }
    )

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsDisplay(bounds)
        watchdog.requested()
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

    /// A LOCAL `NSEvent` monitor, not a `scrollWheel(with:)` override —
    /// deliberate. In Compare's Split mode, `CompareDividerOverlay`'s
    /// full-area background `Color.clear` sits ON TOP of this view (same
    /// SwiftUI `ZStack`), so an unhandled scroll event on a plain override
    /// would never even reach this view — SwiftUI's own hosting responder
    /// chain would route the event elsewhere first, the same "sibling
    /// overlay swallows it" trap `CompareDividerOverlay`'s own gesture
    /// redesign already had to work around for click-drag. A local
    /// monitor intercepts the event BEFORE that dispatch, so it fires
    /// identically regardless of what SwiftUI overlays happen to be
    /// stacked on top this frame — needed for zoom to work in Split too.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installScrollMonitorIfNeeded()
    }

    private func installScrollMonitorIfNeeded() {
        guard window != nil, scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window, event.window === window, self.zoomEnabled,
                  let onScrollZoom = self.onScrollZoom
            else { return event }
            let pointInView = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(pointInView) else { return event }
            // MTKView is unflipped (y-UP, origin bottom-left) — flip
            // once, here, back to SwiftUI's y-DOWN convention, so
            // nothing else in this feature (ZoomPanGeometry,
            // ContentView's state, the pan gesture) ever has to
            // reason about this view's own coordinate flavor.
            let fraction = CGPoint(
                x: pointInView.x / self.bounds.width, y: 1 - pointInView.y / self.bounds.height
            )
            onScrollZoom(fraction, event.scrollingDeltaY)
            return nil // consumed — don't let it fall through to anything else
        }
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }
}
