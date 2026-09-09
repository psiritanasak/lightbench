import SwiftUI

/// D8 (IMPROVEMENTS.md): the keyboard-driven crosshair shown while WB
/// eyedropper pick or Red-Eye placement is armed and the image pane has
/// keyboard focus — arrow keys move it (see `ContentView.
/// handleImagePaneKeyPress`), Return commits at its position. Purely
/// presentational, `.allowsHitTesting(false)` — mouse tap-to-pick/tap-to-
/// place are completely untouched by this view's existence.
///
/// Deliberately a "+" reticle, NOT `RedEyeOverlayView.marker(at:)`'s ring
/// shape — reviewer-caught: an earlier version reused that exact ring
/// (same size/colors), so once Red-Eye's Return committed a point, the
/// crosshair sat pixel-identical on top of the marker it just created,
/// giving a keyboard user zero visual confirmation the point landed (or
/// that a second Return would remove it again). A genuinely different
/// shape keeps "aiming, not yet committed" visually distinct from
/// "already placed" in both modes. Still uses the same black-3.5-under-
/// colored-2 stroke technique for legibility over any image content.
struct EditorCrosshairOverlay: View {
    let fitRect: CGRect
    /// Normalized 0...1, SwiftUI-local/y-DOWN — same convention
    /// `ImageDocumentModel.pickWhiteBalance`/`RedEyePoint` already use.
    let normalizedPosition: CGPoint
    let tint: Color

    private let armLength: CGFloat = 14
    private let gap: CGFloat = 4

    var body: some View {
        let point = CGPoint(
            x: fitRect.minX + normalizedPosition.x * fitRect.width,
            y: fitRect.minY + normalizedPosition.y * fitRect.height
        )
        ZStack {
            crosshairPath.stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            crosshairPath.stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: armLength * 2, height: armLength * 2)
        .position(point)
        .allowsHitTesting(false)
    }

    /// A "+" with a small gap at the center (a common focus-reticle
    /// convention) in this view's own LOCAL `armLength * 2` square —
    /// `.position(point)` (above) then places that square's center at
    /// the actual on-screen point.
    private var crosshairPath: Path {
        Path { path in
            let center = armLength
            path.move(to: CGPoint(x: 0, y: center))
            path.addLine(to: CGPoint(x: center - gap, y: center))
            path.move(to: CGPoint(x: center + gap, y: center))
            path.addLine(to: CGPoint(x: center * 2, y: center))
            path.move(to: CGPoint(x: center, y: 0))
            path.addLine(to: CGPoint(x: center, y: center - gap))
            path.move(to: CGPoint(x: center, y: center + gap))
            path.addLine(to: CGPoint(x: center, y: center * 2))
        }
    }
}
