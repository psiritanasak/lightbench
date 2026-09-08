import SwiftUI

/// Interactive Red-Eye correction markers, overlaid on the image while
/// `ContentView` is in Red-Eye placement mode. Structurally mirrors
/// `CropOverlayView` (an `fitRect`-sized/positioned container, children in
/// its own local coordinate space) more than the WB eyedropper's one-shot
/// tap capture, since this needs to render PERSISTENT markers for every
/// placed point, not just capture a single tap.
///
/// Tapping ADDS a new point at that location, unless the tap lands near an
/// EXISTING marker, in which case it REMOVES that point instead — the
/// hit-test/toggle decision itself lives in `RedEyeHitTest` (pure, directly
/// testable), this view only handles rendering and gesture wiring.
struct RedEyeOverlayView: View {
    let fitRect: CGRect
    @Binding var points: [RedEyePoint]

    private let markerRadius: CGFloat = 12
    private let hitTestThreshold: CGFloat = 16

    var body: some View {
        ZStack {
            ForEach(points.indices, id: \.self) { index in
                marker(at: screenPoint(for: points[index]))
            }
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(coordinateSpace: .local).onEnded { tap in
                        toggle(at: tap.location)
                    }
                )
        }
        .frame(width: fitRect.width, height: fitRect.height)
        .position(x: fitRect.midX, y: fitRect.midY)
        // D6 (IMPROVEMENTS.md): tap-to-place/tap-to-remove is a spatial
        // gesture with no non-mouse equivalent yet — hidden rather than
        // left silently present-but-unreachable. Not a total dead end for
        // AT: the already-labeled "Clear All Red-Eye Corrections" button
        // (`AdjustTabView.swift`) remains a reachable escape hatch, just
        // not a way to place points in the first place — a genuine gap,
        // see IMPROVEMENTS.md's D8 for the actual tracked follow-up.
        .accessibilityHidden(true)
    }

    /// Maps a stored point (normalized 0...1, SwiftUI-local/y-down — same
    /// convention `ImageDocumentModel.pickWhiteBalance` uses for capture)
    /// to this view's own LOCAL coordinate space (0...fitRect.width/height,
    /// matching `CropOverlayView`'s own local-space convention for its
    /// handles).
    private func screenPoint(for point: RedEyePoint) -> CGPoint {
        CGPoint(x: point.x * fitRect.width, y: point.y * fitRect.height)
    }

    private func marker(at point: CGPoint) -> some View {
        ZStack {
            Circle().stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 3.5))
            Circle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 2))
        }
        .frame(width: markerRadius * 2, height: markerRadius * 2)
        .position(point)
        .allowsHitTesting(false)
    }

    private func toggle(at tap: CGPoint) {
        let screenPoints = points.map(screenPoint(for:))
        if let index = RedEyeHitTest.nearestPointIndex(to: tap, in: screenPoints, threshold: hitTestThreshold) {
            points.remove(at: index)
        } else {
            points.append(RedEyePoint(x: tap.x / fitRect.width, y: tap.y / fitRect.height))
        }
    }
}
