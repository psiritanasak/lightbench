import SwiftUI

/// Interactive move/resize handles for the SELECTED mask's linear
/// (graduated band) region, overlaid on the image while a mask is being
/// edited — Phase 7 slice 3 Session B. Structural sibling of
/// `MaskOverlayView` (the Radial mask's own overlay): same snapshot-
/// baseline drag, same coordinate-space rule, same two-pass stroke style,
/// same value-changed write guards — copied line-for-line where the
/// different geometry allows, not reinvented.
///
/// Three narrow bindings (not `Binding<Mask>`) — same rationale as
/// `MaskOverlayView`'s own four: this view structurally cannot touch any
/// non-geometry mask field, let alone any other mask or global `EditState`
/// field. `rotationDegrees` is a plain `let` for the same reason
/// `MaskOverlayView`'s own `rotationDegrees` is — see below.
///
/// Coordinate space: renders directly in the PARENT's space, like
/// `MaskOverlayView` — for an even stronger reason here: a Linear mask's
/// guide LINES are conceptually unbounded (the render itself clamps to
/// `color0`/`color1` beyond `point0`/`point1`, per `LinearMaskGeometry`'s
/// own doc comment), so there is no natural `fitRect`-confined shape to
/// frame this view to at all. Every point here is an absolute
/// `fitRect`-relative coordinate computed directly in the surrounding
/// `ZStack`'s space, with no enclosing `.frame`/`.position` on the whole
/// overlay.
struct LinearMaskOverlayView: View {
    let fitRect: CGRect
    @Binding var centerX: Double
    @Binding var centerY: Double
    @Binding var width: Double
    /// Read-only in v1 — same rationale as `MaskOverlayView`'s own
    /// `rotationDegrees`: no rotation-gesture precedent exists anywhere in
    /// this app, and inventing one is a real, separate design decision out
    /// of scope here. Skipping the HANDLE doesn't skip the MATH: the two
    /// guide handles below still sit on the ROTATED axis via
    /// `MaskGeometry`, so a later rotation handle would be purely
    /// additive UI.
    let rotationDegrees: Double

    @State private var start: (centerX: Double, centerY: Double, width: Double)?

    private var center: CGPoint {
        MaskGeometry.linearGuidePoint(
            .center, centerX: centerX, centerY: centerY, rotationDegrees: rotationDegrees,
            width: width, fitRect: fitRect
        )
    }

    /// Same reviewer-caught guard `MaskOverlayView` already has: a hand-
    /// edited/corrupt sidecar can produce a NaN `centerX`/`width` (`Mask`'s
    /// decoder clamps nothing) — the render already handles this safely
    /// (`LinearMaskGeometry.resolve` returns `nil`), but this overlay would
    /// otherwise hand NaN straight to `.frame(width:)`/`.position(_:)`.
    private var isGeometryFinite: Bool {
        centerX.isFinite && centerY.isFinite && width.isFinite && rotationDegrees.isFinite
    }

    var body: some View {
        if isGeometryFinite {
            content
        }
    }

    private var content: some View {
        ZStack {
            fullEffectGuide
            noEffectGuide
            centerLine
            centerDragArea
            handles
        }
        // Same D8-era precedent `MaskOverlayView` already cites: a mouse-
        // only gesture surface with no accessibility element of its own is
        // hidden rather than left silently present-but-inert in the AX
        // tree — defensible ONLY because every value this overlay lets you
        // drag is independently AT-adjustable via `MaskDetailView`'s
        // Linear-mask slider rows (Center X/Y, Angle, Width).
        .accessibilityHidden(true)
    }

    // MARK: - Visuals

    /// Long enough to span `fitRect` at any rotation, any on-screen
    /// position (including one dragged to an edge — `movedCenter` clamps
    /// `centerX`/`centerY` to `0...1` precisely to allow that), for both
    /// the center line and the two guide lines (each offset up to
    /// `halfWidthPoints` from center) — a Linear mask's guide lines are
    /// conceptually unbounded, so this is a drawing/hit-testing
    /// convenience, not a geometric truth the way `fitRect` itself is.
    ///
    /// Reviewer-caught: an earlier draft used `hypot(...) * 1.5`, i.e. a
    /// HALF-length of `0.75 × diagonal` — too short, measured live to
    /// visibly terminate mid-image for any `centerX` outside roughly
    /// `[0.1, 0.9]` at rotation 0. Delegated to
    /// `MaskGeometry.guideLineLength` (round-3 reviewer suggestion) so the
    /// exact constant that failed review twice has its own unit-tested
    /// sufficiency proof, not just a doc comment here.
    private var lineLength: CGFloat {
        MaskGeometry.guideLineLength(fitRect: fitRect)
    }

    /// A horizontal line spanning its own frame's full width, vertically
    /// centered — a REAL `Shape` conformance (`path(in rect:)` actually
    /// uses the given `rect`), not a bare literal `Path` value.
    ///
    /// Reviewer-caught: a bare `Path` (built with fixed, absolute
    /// coordinates like `(-half, 0)`) conforms to `Shape` via a trivial
    /// `path(in _: CGRect) -> Path { self }` that IGNORES whatever rect
    /// layout gives it — so `.frame(width:height:)` changes only the
    /// view's LAYOUT box, never the path's own drawn coordinates, and
    /// `.position(_:)` centers that box (not the path's own logical
    /// center) at the target point. With no `.frame` at all (the original
    /// bug), the box took on the full PROPOSED size of the parent overlay
    /// (effectively the whole image pane), so `.position(center)` placed
    /// the line at `center − (paneWidth/2, paneHeight/2)` instead of
    /// through `center` at all — measured live to render off-frame
    /// entirely. This type sidesteps the whole class of bug by drawing
    /// relative to its OWN given `rect`, the same way `Rectangle`/
    /// `Ellipse` already do — `rect.midY` is guaranteed to coincide with
    /// this view's own rotation/position anchor (`.center`, the default),
    /// regardless of whatever `.frame` height is applied.
    private struct HorizontalLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }

    /// The anchor/50%-effect line — solid, unlike the two guides below.
    private var centerLine: some View {
        ZStack {
            HorizontalLine().stroke(Color.black.opacity(0.6), lineWidth: 3)
            HorizontalLine().stroke(Color.white, lineWidth: 1.5)
        }
        .frame(width: lineLength, height: 3)
        .rotationEffect(.degrees(rotationDegrees))
        .position(center)
        .allowsHitTesting(false)
    }

    /// One dashed guide line, marking where the render is fully opaque
    /// (`.fullEffect`) or fully transparent (`.noEffect`) — dashed reuses
    /// the exact "dashed = falloff boundary" visual language
    /// `MaskOverlayView`'s own feather guide already established.
    private func guideLine(_ handle: MaskGeometry.LinearHandle) -> some View {
        let point = MaskGeometry.linearGuidePoint(
            handle, centerX: centerX, centerY: centerY, rotationDegrees: rotationDegrees,
            width: width, fitRect: fitRect
        )
        let dash = StrokeStyle(lineWidth: 1.5, dash: [4, 4])
        let dashBlack = StrokeStyle(lineWidth: 3, dash: [4, 4])
        return ZStack {
            HorizontalLine().stroke(Color.black.opacity(0.6), style: dashBlack)
            HorizontalLine().stroke(Color.white, style: dash)
        }
        .frame(width: lineLength, height: 3)
        .rotationEffect(.degrees(rotationDegrees))
        .position(point)
        .allowsHitTesting(false)
    }

    private var fullEffectGuide: some View { guideLine(.fullEffect) }
    private var noEffectGuide: some View { guideLine(.noEffect) }

    // MARK: - Interaction

    /// A Linear mask has no enclosed "interior" the way an ellipse does —
    /// this invisible, rotated band ALONG the center line is the move
    /// affordance instead. Drawn (as a hit region only) BEFORE `handles`
    /// below in the `ZStack`, so a handle's more specific 30x30 hit target
    /// wins over this band in the region where they'd otherwise overlap —
    /// the same z-ordering `MaskOverlayView` already relies on for its own
    /// interior-area-vs-handles overlap.
    private var centerDragArea: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: lineLength, height: 44)
            .rotationEffect(.degrees(rotationDegrees))
            .position(center)
            .gesture(dragGesture(for: .center))
    }

    private var handles: some View {
        ZStack {
            handle(.fullEffect)
            handle(.noEffect)
        }
    }

    /// Same two-pass black-under-white circle, same 30x30 invisible hit
    /// target `MaskOverlayView`'s own handles use — a circle needs no
    /// re-orientation as the mask rotates.
    ///
    /// Reviewer-noted: at a very small `width` (roughly under 0.05 on a
    /// typical fitRect, i.e. `halfWidthPoints < 15pt`), the two handles'
    /// 30x30 hit targets overlap, and `.noEffect` — added second in
    /// `handles`' own `ZStack` — always wins the overlap. `.fullEffect`
    /// becomes temporarily ungrabbable until `width` is widened again
    /// (via the slider, or by dragging `.noEffect` outward). Accepted,
    /// same class as the Radial overlay's own handle-overlap-at-minimum-
    /// radius edge case — not fixed here.
    private func handle(_ kind: MaskGeometry.LinearHandle) -> some View {
        let point = MaskGeometry.linearGuidePoint(
            kind, centerX: centerX, centerY: centerY, rotationDegrees: rotationDegrees,
            width: width, fitRect: fitRect
        )
        return ZStack {
            Circle().fill(Color.black.opacity(0.6)).frame(width: 11, height: 11)
            Circle().fill(Color.white).frame(width: 8, height: 8)
        }
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .position(point)
        .gesture(dragGesture(for: kind))
    }

    private func dragGesture(for handle: MaskGeometry.LinearHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in onChanged(value, handle: handle) }
            .onEnded { _ in start = nil }
    }

    private func onChanged(_ value: DragGesture.Value, handle: MaskGeometry.LinearHandle) {
        if start == nil {
            start = (centerX, centerY, width)
        }
        guard let start else { return }

        // Same reviewer-mandated value-changed write guards
        // `MaskOverlayView` already has: `minimumDistance: 0` means a bare
        // click with no movement still runs this whole handler — only
        // write back a field that actually CHANGED, so a no-op click
        // doesn't fire `editState`'s `didSet` for an interaction that
        // changed nothing.
        switch handle {
        case .center:
            let moved = MaskGeometry.movedCenter(
                startX: start.centerX, startY: start.centerY, translation: value.translation, fitRect: fitRect
            )
            if moved.x != centerX { centerX = moved.x }
            if moved.y != centerY { centerY = moved.y }
        case .fullEffect, .noEffect:
            let resizedWidth = MaskGeometry.resizedWidth(
                handle, startWidth: start.width, translation: value.translation,
                rotationDegrees: rotationDegrees, fitRect: fitRect
            )
            if resizedWidth != width { width = resizedWidth }
        }
    }
}
