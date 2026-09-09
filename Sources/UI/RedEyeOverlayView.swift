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
    /// D8 (IMPROVEMENTS.md): reports the tapped point (normalized 0...1,
    /// same convention `points` itself uses) so `ContentView` can keep its
    /// keyboard crosshair in sync with the mouse — the direct analogue of
    /// a real bug D4's reviewer caught (mouse clicks there never updated
    /// the keyboard-focus state, so a later keypress could silently act
    /// on the wrong target). Defaulted `nil` so this stays additive; the
    /// one real call site (`ContentView`) always passes it.
    var onTap: ((CGPoint) -> Void)?

    private let markerRadius: CGFloat = 12
    /// `static` (not a plain instance `let`, as this was before D8) so
    /// `ContentView`'s keyboard Red-Eye commit — which calls the SAME
    /// pure `RedEyeHitTest.toggling(_:in:fitRect:threshold:)` this view's
    /// own `toggle(at:)` calls, rather than a hand-rolled second copy of
    /// the add-or-remove logic — passes the EXACT same threshold instead
    /// of duplicating the magic number `16`.
    static let hitTestThreshold: CGFloat = 16

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
        // D6 (IMPROVEMENTS.md): this `Color.clear` tap-capture surface
        // itself is still a spatial mouse-only gesture and vends no
        // meaningful accessibility content of its own, so it stays
        // hidden. D8 (IMPROVEMENTS.md) has since shipped a genuine
        // keyboard equivalent — `ContentView.handleImagePaneKeyPress`'s
        // arrow-keys-move/Return-commits crosshair, sharing this view's
        // OWN `toggle(at:)` logic via `RedEyeHitTest.toggling` — so
        // Red-Eye placement is no longer mouse-only overall, just this
        // one capture layer.
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
        let normalized = CGPoint(x: tap.x / fitRect.width, y: tap.y / fitRect.height)
        points = RedEyeHitTest.toggling(normalized, in: points, fitRect: fitRect, threshold: Self.hitTestThreshold)
        onTap?(normalized)
    }
}
