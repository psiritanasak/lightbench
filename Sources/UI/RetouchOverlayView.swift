import SwiftUI

/// On-image editing handles for the SELECTED retouch spot: the spot circle (drag to move it, the source circle
/// travels along), the dashed SOURCE circle (drag to choose where the repair is copied from), joined by a line, and a small
/// RADIUS handle on the spot's right edge (drag to resize; `onRadiusCommitted` reports the final size so the Place Spots tool can
/// remember it).
/// Shown only at identity geometry (`RetouchSpot` explains why) and only while the Retouch tab has a spot
/// selected. Modelled on `MaskOverlayView`: one narrow `Binding<RetouchSpot>`, a snapshot baseline per drag,
/// everything drawn in the pane's space and CLIPPED to the pane (`paneSize`) — drawing only: a handle whose centre has been
/// panned off the pane is also switched off for presses (`RetouchOverlayGeometry.isInsidePane`), since `clipped()` does not limit hit-testing.
/// `.accessibilityHidden(true)` is defensible ONLY because the same values are AT-adjustable in the Remove
/// section's labeled sliders (Size, Source X/Y) — a mouse-only surface otherwise.
struct RetouchOverlayView: View {
    /// Where the picture is DISPLAYED in pane coordinates (the zoomed rect when zoomed — callers pass `ZoomPanGeometry.displayedRect`;
    /// see `RetouchSpotsOverlay.fitRect`).
    let fitRect: CGRect
    /// The pane's size: the handles clip themselves to it so a zoomed picture's circles never draw over the tab bar or sidebar.
    let paneSize: CGSize
    @Binding var spot: RetouchSpot
    /// Called once when a radius-handle drag ends, with the spot's new radius.
    var onRadiusCommitted: ((Double) -> Void)?

    @State private var centerBaseline: (x: Double, y: Double)?
    @State private var offsetBaseline: (dx: Double, dy: Double)?
    @State private var radiusBaseline: Double?

    var body: some View {
        if spot.isFinite, fitRect.width > 0, fitRect.height > 0 {
            let center = RetouchOverlayGeometry.centerPoint(of: spot, in: fitRect)
            let source = RetouchOverlayGeometry.sourcePoint(of: spot, in: fitRect)
            let radius = visibleRadius(of: spot)
            ZStack {
                Path { path in
                    path.move(to: center)
                    path.addLine(to: source)
                }
                .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .allowsHitTesting(false)
                circle(at: source, radius: radius, dashed: true)
                    .gesture(sourceDrag)
                    .allowsHitTesting(RetouchOverlayGeometry.isInsidePane(source, paneSize: paneSize))
                circle(at: center, radius: radius, dashed: false)
                    .gesture(centerDrag)
                    .allowsHitTesting(RetouchOverlayGeometry.isInsidePane(center, paneSize: paneSize))
                radiusHandle(center: center, visibleRadius: radius)
                    .gesture(radiusDrag)
                    .allowsHitTesting(RetouchOverlayGeometry.isInsidePane(
                        CGPoint(x: center.x + radius, y: center.y), paneSize: paneSize))
            }
            .frame(width: paneSize.width, height: paneSize.height)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
        }
    }

    private func circle(at point: CGPoint, radius: CGFloat, dashed: Bool) -> some View {
        ZStack {
            Circle().stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 3, dash: dashed ? [5, 4] : []))
            Circle().stroke(dashed ? Color.cyan : Color.white, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [5, 4] : []))
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .position(point)
    }

    /// The circle's DRAWN radius: its real radius, but never under 6 pt so a tiny spot's circle and handle stay visible/grabbable.
    private func visibleRadius(of spot: RetouchSpot) -> CGFloat {
        max(RetouchOverlayGeometry.radiusPoints(of: spot, in: fitRect), 6)
    }

    /// The resize handle: a small dot on the circle's right edge, drawn on top of the move-disc so it wins the hit test.
    private func radiusHandle(center: CGPoint, visibleRadius: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
            .frame(width: 9, height: 9)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .position(CGPoint(x: center.x + visibleRadius, y: center.y))
    }

    private var radiusDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if radiusBaseline == nil { radiusBaseline = spot.radius }
                guard let baseRadius = radiusBaseline else { return }
                // The handle's position at the START of the drag (where it was DRAWN) moved by the translation is the pointer; the
                // radius is its distance from the unmoving centre. The baseline radius keeps this independent of resizes made
                // mid-drag, and starting from the drawn position means the handle never lags the pointer on a tiny spot.
                var base = spot
                base.radius = baseRadius
                let center = RetouchOverlayGeometry.centerPoint(of: base, in: fitRect)
                let pointer = CGPoint(x: center.x + visibleRadius(of: base) + value.translation.width,
                                      y: center.y + value.translation.height)
                if let r = RetouchOverlayGeometry.radius(fromCenter: center, dragPoint: pointer, fitRect: fitRect) { spot.radius = r }
            }
            .onEnded { _ in
                if radiusBaseline != nil, spot.radius.isFinite { onRadiusCommitted?(spot.radius) }
                radiusBaseline = nil
            }
    }

    private var centerDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if centerBaseline == nil { centerBaseline = (spot.x, spot.y) }
                guard let base = centerBaseline else { return }
                let moved = RetouchOverlayGeometry.movedCenter(baseline: base, translation: value.translation, fitRect: fitRect)
                spot.x = moved.x
                spot.y = moved.y
            }
            .onEnded { _ in centerBaseline = nil }
    }

    private var sourceDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if offsetBaseline == nil { offsetBaseline = (spot.sourceDX, spot.sourceDY) }
                guard let base = offsetBaseline else { return }
                let moved = RetouchOverlayGeometry.movedOffset(baseline: base, translation: value.translation, fitRect: fitRect)
                spot.sourceDX = moved.dx
                spot.sourceDY = moved.dy
            }
            .onEnded { _ in offsetBaseline = nil }
    }
}
