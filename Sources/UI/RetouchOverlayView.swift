import SwiftUI

/// On-image editing handles for the SELECTED retouch spot: the spot circle (drag to move it, the source circle
/// travels along) and the dashed SOURCE circle (drag to choose where the repair is copied from), joined by a line.
/// Shown only at identity geometry (`RetouchSpot` explains why) and only while the Remove section has a spot
/// selected. Modelled on `MaskOverlayView`: one narrow `Binding<RetouchSpot>`, a snapshot baseline per drag,
/// everything drawn directly in the parent's space (no enclosing frame) so circles near the edge still hit-test.
/// `.accessibilityHidden(true)` is defensible ONLY because the same values are AT-adjustable in the Remove
/// section's labeled sliders (Size, Source X/Y) — a mouse-only surface otherwise.
struct RetouchOverlayView: View {
    let fitRect: CGRect
    @Binding var spot: RetouchSpot

    @State private var centerBaseline: (x: Double, y: Double)?
    @State private var offsetBaseline: (dx: Double, dy: Double)?

    var body: some View {
        if spot.isFinite, fitRect.width > 0, fitRect.height > 0 {
            let center = RetouchOverlayGeometry.centerPoint(of: spot, in: fitRect)
            let source = RetouchOverlayGeometry.sourcePoint(of: spot, in: fitRect)
            let radius = max(RetouchOverlayGeometry.radiusPoints(of: spot, in: fitRect), 6)
            ZStack {
                Path { path in
                    path.move(to: center)
                    path.addLine(to: source)
                }
                .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .allowsHitTesting(false)
                circle(at: source, radius: radius, dashed: true)
                    .gesture(sourceDrag)
                circle(at: center, radius: radius, dashed: false)
                    .gesture(centerDrag)
            }
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
