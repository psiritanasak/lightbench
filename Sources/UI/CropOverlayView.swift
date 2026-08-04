import SwiftUI

/// Interactive drag-handle crop rectangle, overlaid on the image while
/// `ContentView` is in crop-editing mode. Presentation-only: it reads and
/// writes the SAME `EditState.cropInsetTop/Bottom/Left/Right` fields the
/// numeric sliders already bind to (four individual bindings, not the whole
/// `EditState`, so this view structurally cannot touch any non-crop field),
/// so `EditState`/`EditPipeline` need no changes at all.
///
/// Coordinate math: `fitRect` is the on-screen rect the image currently
/// occupies, in the SAME SwiftUI point space this view is laid out in
/// (`ContentView` computes it via `AspectFit.rect(fitting:in:)`, the exact
/// function the Metal renderer itself uses, so the two always agree).
/// `cropInsetTop` was verified (`testCropTopInsetRemovesTopContent`) to trim
/// the image's VISUAL top — in `CIImage`'s own bottom-left/y-up space that's
/// the HIGH-y region, but SwiftUI's point space is top-left-origin/y-down, so
/// visual top there is LOW-y (near `fitRect.minY`). Since both spaces agree
/// on what "visual top" MEANS (even though the y-value that represents it
/// differs between them), the mapping below is a direct add with no flip to
/// get backwards — `cropInsetTop` growing moves the rect's top edge DOWN from
/// `fitRect.minY`, exactly matching the visual trim `applyCrop` performs:
/// ```
/// x = fitRect.minX + fitRect.width  * left
/// y = fitRect.minY + fitRect.height * top
/// width  = fitRect.width  * (1 - left - right)
/// height = fitRect.height * (1 - top - bottom)
/// ```
struct CropOverlayView: View {
    let fitRect: CGRect
    @Binding var cropInsetTop: Double
    @Binding var cropInsetBottom: Double
    @Binding var cropInsetLeft: Double
    @Binding var cropInsetRight: Double

    /// Mirrors `EditPipeline.kMaxCropInset` (private there, so duplicated
    /// here as a named constant rather than a magic number). Clamping to
    /// this on every drag frame — not just relying on `applyCrop`'s own
    /// silent clamp at render time — keeps the overlay's rectangle always in
    /// exact agreement with what would actually render, and gives the user a
    /// firm stop at the minimum ~10%-per-dimension crop size rather than a
    /// handle that feels like it's "sticking" unpredictably.
    private let maxInset = 0.45

    private enum Handle {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
        case interior
    }

    /// Snapshot of all four insets taken at the start of the current drag,
    /// so `onChanged` always computes from a fixed baseline plus the
    /// gesture's cumulative translation, rather than compounding deltas
    /// frame-to-frame (which would drift/accelerate). `nil` when no drag is
    /// in progress. Only one handle is ever dragged at a time (SwiftUI
    /// delivers one gesture stream per active touch/mouse-down), so a single
    /// shared snapshot is sufficient.
    @State private var start: (top: Double, bottom: Double, left: Double, right: Double)?

    private var cropRect: CGRect {
        CGRect(
            x: fitRect.minX + fitRect.width * cropInsetLeft,
            y: fitRect.minY + fitRect.height * cropInsetTop,
            width: fitRect.width * (1 - cropInsetLeft - cropInsetRight),
            height: fitRect.height * (1 - cropInsetTop - cropInsetBottom)
        )
    }

    var body: some View {
        ZStack {
            dimming
            border
            thirdsGrid
            interiorDragArea
            handles
        }
        .frame(width: fitRect.width, height: fitRect.height)
        .position(x: fitRect.midX, y: fitRect.midY)
    }

    // MARK: - Visuals

    /// Darkens everything outside the crop rect via a single even-odd path
    /// (outer full-frame rect + inner crop rect) rather than four separate
    /// rectangles — one shape, no seams. Never intercepts drags meant for
    /// the handles/interior beneath it.
    private var dimming: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: fitRect.size))
            path.addRect(cropRect.offsetBy(dx: -fitRect.minX, dy: -fitRect.minY))
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var border: some View {
        Rectangle()
            .stroke(Color.white, lineWidth: 1)
            .frame(width: cropRect.width, height: cropRect.height)
            .position(x: cropRect.midX - fitRect.minX, y: cropRect.midY - fitRect.minY)
            .allowsHitTesting(false)
    }

    private var thirdsGrid: some View {
        let local = cropRect.offsetBy(dx: -fitRect.minX, dy: -fitRect.minY)
        return ZStack {
            // Dark "shadow" stroke under each line so it stays legible over
            // bright image content, not just dark.
            GridLines.minor(in: local)
                .stroke(Color.black.opacity(0.5), lineWidth: 1.5)
            GridLines.minor(in: local)
                .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
            GridLines.major(in: local)
                .stroke(Color.black.opacity(0.6), lineWidth: 2.5)
            GridLines.major(in: local)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Interaction

    private var interiorDragArea: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: cropRect.width, height: cropRect.height)
            .position(x: cropRect.midX - fitRect.minX, y: cropRect.midY - fitRect.minY)
            .gesture(dragGesture(for: .interior))
    }

    private var handles: some View {
        ZStack {
            handle(.topLeft, x: cropRect.minX, y: cropRect.minY)
            handle(.top, x: cropRect.midX, y: cropRect.minY)
            handle(.topRight, x: cropRect.maxX, y: cropRect.minY)
            handle(.left, x: cropRect.minX, y: cropRect.midY)
            handle(.right, x: cropRect.maxX, y: cropRect.midY)
            handle(.bottomLeft, x: cropRect.minX, y: cropRect.maxY)
            handle(.bottom, x: cropRect.midX, y: cropRect.maxY)
            handle(.bottomRight, x: cropRect.maxX, y: cropRect.maxY)
        }
    }

    /// A 12pt visible marker with a larger (30pt) invisible hit target, so
    /// the handle is comfortable to grab with a mouse without needing to be
    /// visually oversized.
    private func handle(_ kind: Handle, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .position(x: x - fitRect.minX, y: y - fitRect.minY)
            .gesture(dragGesture(for: kind))
    }

    private func dragGesture(for handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in onChanged(value, handle: handle) }
            .onEnded { _ in start = nil }
    }

    private func onChanged(_ value: DragGesture.Value, handle: Handle) {
        if start == nil {
            start = (cropInsetTop, cropInsetBottom, cropInsetLeft, cropInsetRight)
        }
        guard let start else { return }

        let dx = fitRect.width > 0 ? value.translation.width / fitRect.width : 0
        let dy = fitRect.height > 0 ? value.translation.height / fitRect.height : 0

        func clamp(_ x: Double) -> Double {
            min(max(x, 0), maxInset)
        }

        switch handle {
        case .top:
            cropInsetTop = clamp(start.top + dy)
        case .bottom:
            cropInsetBottom = clamp(start.bottom - dy)
        case .left:
            cropInsetLeft = clamp(start.left + dx)
        case .right:
            cropInsetRight = clamp(start.right - dx)
        case .topLeft:
            cropInsetTop = clamp(start.top + dy)
            cropInsetLeft = clamp(start.left + dx)
        case .topRight:
            cropInsetTop = clamp(start.top + dy)
            cropInsetRight = clamp(start.right - dx)
        case .bottomLeft:
            cropInsetBottom = clamp(start.bottom - dy)
            cropInsetLeft = clamp(start.left + dx)
        case .bottomRight:
            cropInsetBottom = clamp(start.bottom - dy)
            cropInsetRight = clamp(start.right - dx)
        case .interior:
            // Translate the whole rect: size stays fixed (top+bottom and
            // left+right sums are preserved), confined so no side crosses
            // the frame's own edge AND no side exceeds `maxInset`. Bounding
            // dx to [-left, right] alone only keeps `left + right` (which can
            // already be up to 2*maxInset) from crossing zero/negative — it
            // does NOT stop the translation from piling that whole sum onto
            // one side past `maxInset` (e.g. left 0.1/right 0.4 sliding to
            // left 0.5 at tx=0.4), which would silently desync the overlay
            // from `EditPipeline.applyCrop`'s own independent per-side clamp.
            // So tx/ty are ALSO bounded by each side's `maxInset` headroom.
            let tx = min(max(dx, max(-start.left, start.right - maxInset)), min(start.right, maxInset - start.left))
            let ty = min(max(dy, max(-start.top, start.bottom - maxInset)), min(start.bottom, maxInset - start.top))
            cropInsetLeft = start.left + tx
            cropInsetRight = start.right - tx
            cropInsetTop = start.top + ty
            cropInsetBottom = start.bottom - ty
        }
    }
}
