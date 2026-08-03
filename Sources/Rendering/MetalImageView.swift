import MetalKit
import SwiftUI

/// Displays a `CIImage` in a Metal-backed view, aspect-fit and centered.
struct MetalImageView: NSViewRepresentable {
    var image: CIImage?
    var editState: EditState

    func makeNSView(context: Context) -> MTKView {
        let renderer = context.coordinator
        let view = ResizingMTKView(frame: .zero, device: renderer.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .rgba16Float
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = renderer
        return view
    }

    /// Skips the redraw entirely when neither `image` nor `editState` actually
    /// changed since the last call. SwiftUI re-invokes `updateNSView` on any
    /// observed document change, but during an interactive crop drag the
    /// image shown here (`ContentView`'s `displayEditState`, with crop insets
    /// zeroed) is intentionally held constant while only the crop overlay
    /// moves — this guard keeps those frames free of redundant Core Image
    /// pipeline re-runs. `image` is compared by reference (`currentImage` is
    /// only ever reassigned wholesale on load, never mutated in place) and
    /// `editState` by value (`Equatable`).
    func updateNSView(_ nsView: MTKView, context: Context) {
        let renderer = context.coordinator
        guard image !== renderer.image || editState != renderer.editState else { return }
        renderer.image = image
        renderer.editState = editState
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
}
