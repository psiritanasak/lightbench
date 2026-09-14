import SwiftUI

/// The LIVE in-progress brush stroke overlay — Phase 7 slice 4. Unlike
/// `MaskOverlayView`/`LinearMaskOverlayView` (persistent handle-based
/// editing surfaces for an already-placed shape), this view exists ONLY
/// while `ContentView.brushPaintingMaskID` is armed for the mask it's bound
/// to: there is no "select a placed stroke and drag its handles"
/// interaction in v1 — Size/Feather sliders plus "Redraw Stroke", both in
/// `MaskDetailView`, are the only post-paint editing surface (see
/// `Mask.brushPoints`'s own doc comment).
///
/// Renders directly in the PARENT's space, like `MaskOverlayView`/
/// `LinearMaskOverlayView` — load-bearing, NOT stylistic: this view must
/// NEVER be wrapped in an enclosing `.frame`/`.position`, the exact bug
/// class `LinearMaskOverlayView.HorizontalLine`'s own doc comment records
/// (a bare `Path` conforms to `Shape` via a trivial `path(in:) { self }`
/// that IGNORES the given layout rect, so wrapping it moved only the
/// irrelevant layout box while the path itself rendered off-screen —
/// caught only because a reviewer actually RENDERED the view, not by any
/// unit test). The capture layer below is similarly left UNFRAMED, on
/// purpose: with no `.frame`, it takes on the full proposed size of the
/// surrounding `ZStack` (the whole image pane, per `pointAndZoomOverlays`'s
/// own `GeometryReader`), so `DragGesture(coordinateSpace: .local)`
/// reports coordinates directly in that same pane-absolute space `fitRect`
/// itself is expressed in — no extra offset conversion needed before
/// calling `MaskGeometry.normalizedBrushPoint`.
struct BrushMaskOverlayView: View {
    let fitRect: CGRect
    @Binding var points: [BrushPoint]
    let brushSize: Double
    /// Called on `DragGesture.onEnded` — auto-disarms paint mode the
    /// moment the mouse is released (WB's "arm then auto-disarm after one
    /// interaction" shape, NOT Red-Eye's "stays armed" shape).
    let onStrokeEnded: () -> Void

    @State private var isStrokeInProgress = false
    @State private var lastAppendedLocation: CGPoint?

    /// Bounds how large `brushPoints` can grow on a pathologically slow/
    /// long drag — each appended point is a full `editState` write. Not
    /// expected to matter at any normal painting speed/duration; a purely
    /// defensive ceiling, the same role `RedEyeHitTest`'s own bounds play
    /// for that feature's point list.
    private static let maximumPointCount = 4000

    /// Same reviewer-caught guard every other mask overlay has: a hand-
    /// edited/corrupt sidecar's NaN must not reach `Path`/`.position`
    /// directly.
    private var isGeometryFinite: Bool {
        brushSize.isFinite && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    var body: some View {
        if isGeometryFinite {
            content
        }
    }

    /// Reads the SAME `BrushMaskGeometry.radiusInPixels` the render itself
    /// uses, so this live preview's width can never drift from what
    /// actually gets painted.
    private var radiusPoints: CGFloat {
        BrushMaskGeometry.radiusInPixels(brushSize: brushSize, extent: fitRect)
    }

    private var screenPoints: [CGPoint] {
        points.map { MaskGeometry.brushScreenPoint($0, fitRect: fitRect) }
    }

    private var strokePath: Path {
        Path { path in
            guard let first = screenPoints.first else { return }
            path.move(to: first)
            for point in screenPoints.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private var content: some View {
        ZStack {
            strokeBand
            centerLine
            captureLayer
        }
        // A real, ACCEPTED accessibility gap (see `MaskDetailView`'s own
        // doc comment and IMPROVEMENTS.md), NOT the same justification
        // Radial/Linear's overlays rely on: every value THOSE overlays let
        // you drag is independently AT-adjustable via a slider elsewhere;
        // a brush stroke's PATH has no slider equivalent at all.
        .accessibilityHidden(true)
    }

    // MARK: - Visuals

    /// The translucent live-paint band, at the TRUE brush width.
    private var strokeBand: some View {
        strokePath
            .stroke(
                Color.white.opacity(0.35),
                style: StrokeStyle(lineWidth: radiusPoints * 2, lineCap: .round, lineJoin: .round)
            )
            .allowsHitTesting(false)
    }

    /// Thin black-under-white centerline — the same two-pass legibility
    /// idiom `MaskOverlayView`/`LinearMaskOverlayView` already use, here
    /// tracing the actual painted path instead of a fixed guide line.
    private var centerLine: some View {
        ZStack {
            strokePath.stroke(Color.black.opacity(0.6), lineWidth: 3)
            strokePath.stroke(Color.white, lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Interaction

    /// Reviewer-caught: `onStrokeEnded()` (below) tears this whole view down
    /// — `ContentView` stops rendering it the moment `brushPaintingMaskID`
    /// clears — while the pointer is typically still INSIDE it, so
    /// `.onHover`'s own `false` case never fires and every stroke leaked
    /// one extra `NSCursor.push()`. Tracked locally so `.onDisappear` can
    /// pop exactly the pushes THIS view made, never more.
    @State private var isHoveringCaptureLayer = false

    private var captureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                isHoveringCaptureLayer = inside
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHoveringCaptureLayer { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged(onChanged)
                    .onEnded { _ in
                        isStrokeInProgress = false
                        lastAppendedLocation = nil
                        onStrokeEnded()
                    }
            )
    }

    private func onChanged(_ value: DragGesture.Value) {
        if !isStrokeInProgress {
            // F5: the FIRST callback of a NEW gesture replaces the array
            // wholesale — this is what makes "Redraw Stroke" replace the
            // old stroke only once drawing actually starts, not at arm
            // time (`AdjustTabView.beginBrushStroke` deliberately never
            // clears `brushPoints` itself). Reviewer-caught: this must run
            // BEFORE the `maximumPointCount` guard below — an existing
            // stroke already at the cap would otherwise never be
            // redrawable, only deletable, since the very first callback of
            // the NEW gesture would see the OLD (maxed-out) count and bail
            // before ever replacing it.
            isStrokeInProgress = true
            points = [MaskGeometry.normalizedBrushPoint(value.location, fitRect: fitRect)]
            lastAppendedLocation = value.location
            return
        }

        guard points.count < Self.maximumPointCount else { return }
        guard let lastAppendedLocation,
              MaskGeometry.shouldAppendBrushPoint(value.location, after: lastAppendedLocation)
        else { return }
        points.append(MaskGeometry.normalizedBrushPoint(value.location, fitRect: fitRect))
        self.lastAppendedLocation = value.location
    }
}
