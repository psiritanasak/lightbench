import MetalKit
import SwiftUI

/// Displays a `CIImage` in a Metal-backed view, aspect-fit and centered.
struct MetalImageView: NSViewRepresentable {
    var image: CIImage?

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

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.image = image
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
