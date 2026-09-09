import SwiftUI

/// Interactive resize/move handles for the SELECTED mask's radial (ellipse)
/// region, overlaid on the image while a mask is being edited. Mirrors
/// `CropOverlayView`'s shape (snapshot-baseline drag, a real SwiftUI view
/// per handle) — NOT `RedEyeOverlayView`'s arithmetic hit-testing, since a
/// mask needs continuous resize/move, not tap-to-place.
///
/// Four narrow bindings (not `Binding<Mask>`) — the direct analogue of
/// `CropOverlayView`'s own doc comment: this view structurally cannot touch
/// any non-geometry mask field, let alone any other mask or global
/// `EditState` field. `rotationDegrees`/`feather` are plain `let`s
/// precisely because this view must not write them in v1 (see below).
///
/// Coordinate space: renders directly in the PARENT's space, like
/// `EditorCrosshairOverlay` — UNLIKE `CropOverlayView`, which frames/
/// positions itself to exactly `fitRect` because a crop rect is always
/// inside the image. A mask's ellipse can legitimately extend past the
/// image edge (masking a corner), so its handles can land outside
/// `fitRect` — a child view positioned outside its own parent's frame does
/// not reliably receive hit-test events in SwiftUI. So every point here is
/// an absolute `fitRect`-relative coordinate computed directly in the
/// surrounding `ZStack`'s space, with no enclosing `.frame`/`.position` on
/// the whole overlay.
struct MaskOverlayView: View {
    let fitRect: CGRect
    @Binding var centerX: Double
    @Binding var centerY: Double
    @Binding var radiusX: Double
    @Binding var radiusY: Double
    /// Read-only in v1 — rotation is slider-driven (`MaskDetailView`'s
    /// Rotation row), not a drag handle. No rotation-gesture precedent
    /// exists anywhere in this app (Straighten is a slider; Crop has no
    /// rotation handle), and inventing one (a stalk? absolute-to-cursor?
    /// snapping?) is a real, separate design decision out of scope here.
    /// Skipping the HANDLE doesn't skip the MATH, though: the 4 resize
    /// handles below still sit on the ROTATED ellipse via `MaskGeometry`,
    /// so a later rotation handle would be purely additive UI.
    let rotationDegrees: Double
    /// Read-only — drives only the dashed feather guide, via the SAME
    /// `RadialMaskGeometry.innerRadiusFraction(feather:)` the render
    /// pipeline itself uses, so the guide can never drift from what's
    /// actually solid.
    let feather: Double

    @State private var start: (centerX: Double, centerY: Double, radiusX: Double, radiusY: Double)?

    private var center: CGPoint {
        MaskGeometry.handlePoint(
            .center, centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY,
            rotationDegrees: rotationDegrees, fitRect: fitRect
        )
    }

    /// Reviewer-caught: unlike `RadialMaskGeometry.resolve` (the render
    /// side), this overlay had no non-finite guard of its own. `Mask`'s
    /// decoder is deliberately permissive (clamps nothing), so a hand-
    /// edited/corrupt sidecar can produce a NaN `centerX`/`radiusX` — the
    /// RENDER already handles this safely (`resolve` returns `nil`, the
    /// mask is skipped), but this overlay would otherwise hand NaN
    /// straight to `.frame(width:)`/`.position(_:)`.
    private var isGeometryFinite: Bool {
        centerX.isFinite && centerY.isFinite && radiusX.isFinite && radiusY.isFinite
            && rotationDegrees.isFinite && feather.isFinite
    }

    var body: some View {
        if isGeometryFinite {
            content
        }
    }

    private var content: some View {
        ZStack {
            outline
            featherGuide
            interiorDragArea
            handles
        }
        // D8-era precedent (`CropOverlayView.swift`, `RedEyeOverlayView.swift`):
        // a mouse-only gesture surface with no accessibility element of its
        // own is hidden rather than left silently present-but-inert in the
        // AX tree — defensible ONLY because every value this overlay lets
        // you drag is independently AT-adjustable via `MaskDetailView`'s 14
        // labeled `EditSliderRow`s. If those rows were ever dropped, this
        // would become a real accessibility regression, not a neutral cut.
        .accessibilityHidden(true)
    }

    // MARK: - Visuals

    private var outline: some View {
        let rxPoints = radiusX * fitRect.width
        let ryPoints = radiusY * fitRect.height
        return ZStack {
            Ellipse().stroke(Color.black.opacity(0.6), lineWidth: 3)
            Ellipse().stroke(Color.white, lineWidth: 1.5)
        }
        .frame(width: rxPoints * 2, height: ryPoints * 2)
        .rotationEffect(.degrees(rotationDegrees))
        .position(center)
        .allowsHitTesting(false)
    }

    /// A second, smaller dashed ellipse marking where the mask is still
    /// FULLY opaque — the fully-opaque radius as a FRACTION of the outer
    /// radius comes from `RadialMaskGeometry.innerRadiusFraction(feather:)`,
    /// the exact same function `EditPipeline.applyMasks` uses to build the
    /// real render mask, reused rather than re-derived so this guide can
    /// never lie about where the render is actually solid.
    @ViewBuilder private var featherGuide: some View {
        if feather > RadialMaskGeometry.minimumFeather {
            let fraction = RadialMaskGeometry.innerRadiusFraction(feather: feather)
            let rxPoints = radiusX * fitRect.width * fraction
            let ryPoints = radiusY * fitRect.height * fraction
            Ellipse()
                .stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .frame(width: rxPoints * 2, height: ryPoints * 2)
                .rotationEffect(.degrees(rotationDegrees))
                .position(center)
                .allowsHitTesting(false)
            Ellipse()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 0.75, dash: [4, 4]))
                .frame(width: rxPoints * 2, height: ryPoints * 2)
                .rotationEffect(.degrees(rotationDegrees))
                .position(center)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Interaction

    private var interiorDragArea: some View {
        let rxPoints = radiusX * fitRect.width
        let ryPoints = radiusY * fitRect.height
        return Ellipse()
            .fill(Color.clear)
            .contentShape(Ellipse())
            .frame(width: rxPoints * 2, height: ryPoints * 2)
            .rotationEffect(.degrees(rotationDegrees))
            .position(center)
            .gesture(dragGesture(for: .center))
    }

    private var handles: some View {
        ZStack {
            handle(.plusX)
            handle(.minusX)
            handle(.plusY)
            handle(.minusY)
        }
    }

    /// A small filled circle, NOT Crop's L-shaped brackets/bars — a circle
    /// needs no re-orientation as the ellipse rotates, unlike a bracket
    /// shape that's meaningful only axis-aligned. Same two-pass black-
    /// under-white contrast technique `CropOverlayView`'s own handles use,
    /// and the same 30x30 invisible hit target.
    private func handle(_ kind: MaskGeometry.Handle) -> some View {
        let point = MaskGeometry.handlePoint(
            kind, centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY,
            rotationDegrees: rotationDegrees, fitRect: fitRect
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

    private func dragGesture(for handle: MaskGeometry.Handle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in onChanged(value, handle: handle) }
            .onEnded { _ in start = nil }
    }

    private func onChanged(_ value: DragGesture.Value, handle: MaskGeometry.Handle) {
        if start == nil {
            start = (centerX, centerY, radiusX, radiusY)
        }
        guard let start else { return }

        // Reviewer-caught: `minimumDistance: 0` means a bare click with no
        // movement still runs this whole handler — only write back a
        // field that actually CHANGED, so a no-op click doesn't fire
        // `editState`'s `didSet` (sidecar save/thumbnail invalidation) for
        // an interaction that changed nothing (the same class of bug
        // Post-Phase-5 follow-up #8's reviewer caught for the numeric
        // click-to-type fields). `EditHistory.commit`'s own value-equality
        // guard already prevents a phantom UNDO step either way, but this
        // avoids the wasted work entirely, not just its visible symptom.
        switch handle {
        case .center:
            let moved = MaskGeometry.movedCenter(
                startX: start.centerX, startY: start.centerY, translation: value.translation, fitRect: fitRect
            )
            if moved.x != centerX { centerX = moved.x }
            if moved.y != centerY { centerY = moved.y }
        case .plusX, .minusX, .plusY, .minusY:
            let resized = MaskGeometry.resized(
                handle, startRadiusX: start.radiusX, startRadiusY: start.radiusY,
                translation: value.translation, rotationDegrees: rotationDegrees, fitRect: fitRect
            )
            if resized.radiusX != radiusX { radiusX = resized.radiusX }
            if resized.radiusY != radiusY { radiusY = resized.radiusY }
        }
    }
}
