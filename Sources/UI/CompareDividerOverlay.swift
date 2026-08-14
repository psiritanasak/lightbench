import SwiftUI

/// The draggable divider line for Compare's Split mode. Positioned/sized
/// against `fitRect` — the SAME on-screen rect `ContentView.currentFitRect`
/// computes via `AspectFit.rect`, the exact function `ImageRenderer` itself
/// uses (same precedent `CropOverlayView` documents) — so the on-screen
/// line always lands exactly on the rendered seam. See
/// `ImageRenderer.draw(in:)`'s Split case for which side of the line shows
/// original vs. edited.
///
/// **Two distinct gesture behaviors, chosen live per user feedback**:
/// pressing ON the line/handle grabs it and tracks the cursor's MOVEMENT
/// smoothly; pressing anywhere ELSE jumps the divider straight to that
/// point. A first attempt implemented this as a single gesture that
/// computed "am I close enough to the line to count as a grab?" once per
/// gesture via manual distance bookkeeping — that turned out fragile (grab
/// detection worked for one orientation but kept falling through to "jump"
/// for the other, root cause not fully pinned down). This version sidesteps
/// the ambiguity entirely by using SwiftUI's OWN hit-testing instead of
/// custom state: TWO separate gesture-bearing views layered in the
/// `ZStack` — a wide invisible strip around the line (grab, `translation`-
/// based delta drag, the same start-snapshot shape `CropOverlayView`
/// uses) drawn ON TOP of a full-area background (click-elsewhere, absolute-
/// position jump). SwiftUI routes a press to whichever topmost view's
/// `contentShape` contains it, so which gesture fires is never ambiguous.
struct CompareDividerOverlay: View {
    let fitRect: CGRect
    let orientation: SplitOrientation
    @Binding var position: Double

    /// Width of the invisible grab strip around the line, generous enough
    /// to be comfortable with a mouse (matches `CropOverlayView`'s own
    /// generous-hit-target philosophy for its handles).
    private let grabStripWidth: CGFloat = 48

    private var localFitRect: CGRect { CGRect(origin: .zero, size: fitRect.size) }

    /// Snapshot of `position` at the start of the CURRENT grab drag, so
    /// `onChanged` always computes from a fixed baseline plus the
    /// gesture's cumulative `translation`, rather than compounding deltas
    /// frame to frame — the same pattern `CropOverlayView`'s `start` uses.
    /// `nil` when no grab drag is in progress.
    @State private var grabStart: Double?

    var body: some View {
        ZStack {
            // Background: pressing ANYWHERE ELSE on the image jumps the
            // divider straight to that point. Listed FIRST so `grabStrip`
            // (added last, below) sits on top of it in z-order and wins
            // hit-testing over the region where they overlap.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            position = CompareLayout.dividerFraction(at: value.location, in: localFitRect, orientation: orientation)
                        }
                )

            // Dark "shadow" stroke under the white line so it stays legible
            // over bright image content, not just dark — same technique
            // `CropOverlayView`'s grid/border/handles already use. Purely
            // visual — `allowsHitTesting(false)` so a stroked shape's own
            // (thin, path-shaped) hit area never competes with `grabStrip`/
            // the background below for gesture routing.
            linePath.stroke(Color.black.opacity(0.6), lineWidth: 3).allowsHitTesting(false)
            linePath.stroke(Color.white, lineWidth: 1).allowsHitTesting(false)
            handle

            grabStrip
        }
        .frame(width: fitRect.width, height: fitRect.height)
        .position(x: fitRect.midX, y: fitRect.midY)
    }

    /// The wide, invisible, topmost hit-target centered on the line's
    /// current position — grabbing anywhere in it drags smoothly via
    /// `translation` (a DELTA, invariant to which view's local coordinate
    /// space it's measured in, so no origin-alignment subtlety to get
    /// wrong here, unlike the earlier distance-from-line approach).
    private var grabStrip: some View {
        let point = orientation == .vertical
            ? CGPoint(x: fitRect.width * position, y: fitRect.height / 2)
            : CGPoint(x: fitRect.width / 2, y: fitRect.height * position)
        return Color.clear
            .contentShape(Rectangle())
            .frame(
                width: orientation == .vertical ? grabStripWidth : fitRect.width,
                height: orientation == .vertical ? fitRect.height : grabStripWidth
            )
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if grabStart == nil { grabStart = position }
                        let delta = orientation == .vertical
                            ? value.translation.width / fitRect.width
                            : value.translation.height / fitRect.height
                        position = min(max((grabStart ?? position) + delta, 0), 1)
                    }
                    .onEnded { _ in grabStart = nil }
            )
    }

    private var linePath: Path {
        Path { path in
            switch orientation {
            case .vertical:
                let x = fitRect.width * position
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: fitRect.height))
            case .horizontal:
                let y = fitRect.height * position
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: fitRect.width, y: y))
            }
        }
    }

    /// A small grab-affordance dot at the line's midpoint — same dark-
    /// shadow-under-white-stroke technique as `CropOverlayView`'s handles,
    /// purely visual (the actual hit target is `grabStrip` above, which
    /// covers a much wider area than just this dot).
    private var handle: some View {
        let center = CGPoint(x: fitRect.width / 2, y: fitRect.height / 2)
        let point = orientation == .vertical
            ? CGPoint(x: fitRect.width * position, y: center.y)
            : CGPoint(x: center.x, y: fitRect.height * position)
        return ZStack {
            Circle().stroke(Color.black.opacity(0.6), lineWidth: 3.5)
            Circle().stroke(Color.white, lineWidth: 2)
        }
        .frame(width: 16, height: 16)
        .position(point)
        .allowsHitTesting(false)
    }
}
