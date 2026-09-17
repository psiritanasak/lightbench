import CoreGraphics

/// Pure screen-space math for the Curves v2 point-curve editor
/// (`ToneCurveEditorView`) — the UI-side INVERSE of `MonotoneToneCurve`'s
/// forward render math, the same split `MaskGeometry`/`RadialMaskGeometry`
/// already documents. `import CoreGraphics` only, no SwiftUI — the strict
/// convention shared by `RedEyeHitTest`/`MaskGeometry`/`CropAspectMath`, so
/// this real arithmetic (insertion, clamping, hit-testing) gets direct XCTest
/// coverage instead of being eyeballed through a gesture.
///
/// COORDINATE CONVENTION: `ToneCurvePoint.y` is stored Y-UP (a value, not a
/// screen position — see that type's own doc comment), while `plotRect` is
/// ordinary SwiftUI Y-DOWN screen space. The flip happens ONLY in
/// `screenPoint`/`normalizedPoint` below — every other function here works
/// entirely in normalized curve space and never touches `plotRect` directly,
/// so there is exactly one place a sign error could hide.
enum ToneCurveEditing {
    /// The floor on the x-gap a drag/add/nudge may leave between adjacent
    /// control points. Two orders of magnitude larger than
    /// `MonotoneToneCurve.minimumXSeparation` (1e-4) — that constant exists
    /// only to reject an absurd hand-authored sidecar and still renders a
    /// legally-steep curve; this one is what a live drag actually respects,
    /// so a dragged point visibly STOPS well before it could ever produce
    /// the kind of segment that guard exists to catch.
    static let minimumXSeparation: Double = 1e-2

    /// Hit-test radius, in the same screen points RedEye's own
    /// `RedEyeOverlayView.hitTestThreshold` uses — same interaction scale
    /// (a small handle on a photo-editing canvas), so reusing the exact
    /// value keeps the two point-placement features feeling consistent
    /// rather than picking a new number for no reason.
    static let hitTestThreshold: CGFloat = 16

    /// One arrow-key nudge, in the same 0...1 normalized units control
    /// points are stored in.
    static let nudgeStep: Double = 0.01
    /// One Shift-arrow coarse nudge.
    static let coarseNudgeStep: Double = 0.05

    // MARK: - Screen <-> normalized conversion

    /// Normalized curve point -> screen space. The Y flip lives here and
    /// nowhere else: curve Y is UP (0 = bottom = black, 1 = top = white,
    /// matching the diagonal reference line's visual reading), screen Y is
    /// DOWN, so `plotRect.maxY` (visual bottom) corresponds to curve y = 0.
    static func screenPoint(_ point: ToneCurvePoint, in plotRect: CGRect) -> CGPoint {
        CGPoint(
            x: plotRect.minX + point.x * plotRect.width,
            y: plotRect.maxY - point.y * plotRect.height
        )
    }

    /// Exact inverse of `screenPoint`, clamped to the unit square — a drag
    /// or tap can land outside `plotRect` (common near its edges), and the
    /// stored point must still resolve to a valid, on-curve fraction. This
    /// is the ONLY place x is ever clamped to a bare `0...1` rather than to
    /// a neighbor-relative range — it is the raw conversion, not the
    /// neighbor-aware clamp `clampedInterior` applies afterward for a move.
    static func normalizedPoint(_ location: CGPoint, in plotRect: CGRect) -> ToneCurvePoint {
        guard plotRect.width > 0, plotRect.height > 0 else { return ToneCurvePoint(x: 0.5, y: 0.5) }
        let x = (location.x - plotRect.minX) / plotRect.width
        let y = (plotRect.maxY - location.y) / plotRect.height
        return ToneCurvePoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    // MARK: - Hit testing

    /// The nearest existing point (by screen distance) within
    /// `hitTestThreshold`, or `nil` if a tap at `location` should ADD a new
    /// point instead — the same add-or-remove split `RedEyeHitTest`
    /// established, adapted to a Y-flipped, curve-shaped point set. Ties
    /// broken by FIRST match in array order (a reviewer-caught inaccuracy
    /// in `RedEyeHitTest`'s own copy of this comment: a bare `<=` lets a
    /// later equidistant point overwrite an earlier one, resolving to the
    /// LAST match instead). Not expected to matter in practice, since two
    /// points can't realistically overlap exactly.
    ///
    /// The tie-break condition also makes the threshold boundary
    /// INCLUSIVE: a point at EXACTLY `hitTestThreshold` away counts as a
    /// hit (matching `RedEyeHitTest.nearestPointIndex`'s own `<=`
    /// semantics at the boundary), not just strictly-closer points.
    static func nearestPointIndex(
        to location: CGPoint, in points: [ToneCurvePoint], plotRect: CGRect, threshold: CGFloat = hitTestThreshold
    ) -> Int? {
        var bestIndex: Int?
        var bestDistance = threshold
        for (index, point) in points.enumerated() {
            let screen = screenPoint(point, in: plotRect)
            let distance = hypot(screen.x - location.x, screen.y - location.y)
            if distance < bestDistance || (bestIndex == nil && distance == bestDistance) {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    // MARK: - Editing operations

    /// Adds a point at `location` (screen space), inserting it in x-sorted
    /// order so `points` stays valid input for `MonotoneToneCurve`. Returns
    /// the resulting array AND the new point's index, so a caller (the
    /// drag gesture) can immediately select/drag the point it just created
    /// without a second, distance-based lookup that could in principle
    /// resolve to a DIFFERENT point if two ever end up close together —
    /// `insertedIndex` is computed from the same insertion-position logic
    /// this function already ran, not re-derived.
    ///
    /// SEEDS `[] -> [(0,0),(1,1)]` FIRST, inside this pure function — so the
    /// very-first-ever interaction (an empty curve section, no points at
    /// all) is a unit-tested transition rather than something a gesture
    /// closure has to remember to do before calling this.
    ///
    /// No-ops (`insertedIndex == nil`, `points` unchanged) once already at
    /// `MonotoneToneCurve.maximumPointCount`, or when there is no room to
    /// insert a validly-separated point between two crowded neighbors —
    /// the render cap is silent by design (see that type's own doc
    /// comment: an over-cap curve would render identity, which is worse
    /// than simply refusing the next point).
    ///
    /// Reviewer-noted edge asymmetry, harmless but worth recording: a tap
    /// that normalizes to exactly `x = 1` (the plot rect's own right
    /// margin, reachable since the canvas insets its content) makes
    /// `insertIndex == seeded.count`, pins `rightX` to `1`, and the
    /// `minX <= maxX` guard below then refuses if that tap's `x` is
    /// already within `minimumXSeparation` of the right endpoint — while
    /// the symmetric tap at `x = 0` inserts fine, since `leftX` pins to
    /// `0` on that side instead. Not fixed: the asymmetry is a one-sided
    /// consequence of how the loop finds `insertIndex`, not a
    /// user-visible defect (a tap that close to an endpoint is far more
    /// likely to be a HIT on that endpoint than an add attempt).
    static func adding(
        _ location: CGPoint, to points: [ToneCurvePoint], plotRect: CGRect
    ) -> (points: [ToneCurvePoint], insertedIndex: Int?) {
        let seeded = points.isEmpty ? [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)] : points
        guard seeded.count < MonotoneToneCurve.maximumPointCount else { return (points, nil) }

        var candidate = normalizedPoint(location, in: plotRect)
        var insertIndex = seeded.count
        for i in 0..<seeded.count where candidate.x < seeded[i].x {
            insertIndex = i
            break
        }
        let leftX = insertIndex > 0 ? seeded[insertIndex - 1].x : 0
        let rightX = insertIndex < seeded.count ? seeded[insertIndex].x : 1
        let minX = leftX + minimumXSeparation
        let maxX = rightX - minimumXSeparation
        // No room to insert a validly-separated point between these two
        // neighbors — a no-op rather than an insert that would violate the
        // separation invariant every other function here relies on.
        guard minX <= maxX else { return (points, nil) }
        candidate.x = min(max(candidate.x, minX), maxX)

        var result = seeded
        result.insert(candidate, at: insertIndex)
        return (result, insertIndex)
    }

    /// Adds a point at the horizontal midpoint of the WIDEST gap between
    /// existing points — used by the "Add Point" button, which (unlike a
    /// canvas click) has no location to place a point at. Seeds
    /// `[] -> [(0,0),(1,1)]` first, same as `adding(_:to:plotRect:)`. `y`
    /// is the linear midpoint between the gap's two endpoints — a neutral
    /// starting value that doesn't presume a direction of adjustment.
    /// No-ops under the same two conditions `adding` does: already at the
    /// render cap, or every remaining gap is already at the minimum
    /// separation (nothing left wide enough to split). Use
    /// `canAddAtWidestGap(to:)` to check this BEFORE calling — an "Add
    /// Point" button that stays enabled through a real no-op is exactly
    /// the silently-inert-control trap this codebase's RAW-native sliders
    /// were reviewer-caught shipping once already.
    static func addingAtWidestGap(of points: [ToneCurvePoint]) -> [ToneCurvePoint] {
        guard let split = widestGapSplit(of: points) else { return points }
        var result = split.seeded
        result.insert(split.midpoint, at: split.afterIndex)
        return result
    }

    /// Whether `addingAtWidestGap(of:)` would actually insert a point —
    /// the button-enablement twin of that function, sharing its exact
    /// gap-finding logic via `widestGapSplit` rather than re-deriving the
    /// same two no-op conditions a second time.
    static func canAddAtWidestGap(to points: [ToneCurvePoint]) -> Bool {
        widestGapSplit(of: points) != nil
    }

    private static func widestGapSplit(
        of points: [ToneCurvePoint]
    ) -> (seeded: [ToneCurvePoint], midpoint: ToneCurvePoint, afterIndex: Int)? {
        let seeded = points.isEmpty ? [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)] : points
        guard seeded.count < MonotoneToneCurve.maximumPointCount else { return nil }

        var widestGapIndex = 0
        var widestGap = -Double.infinity
        for i in 0..<(seeded.count - 1) {
            let gap = seeded[i + 1].x - seeded[i].x
            if gap > widestGap {
                widestGap = gap
                widestGapIndex = i
            }
        }
        guard widestGap >= 2 * minimumXSeparation else { return nil }

        let left = seeded[widestGapIndex]
        let right = seeded[widestGapIndex + 1]
        let midpoint = ToneCurvePoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        return (seeded, midpoint, widestGapIndex + 1)
    }

    /// Moves the point at `index` to `location` (screen space). Endpoints
    /// (index 0 and the last index) are PINNED IN X — only their y moves —
    /// so the spline's domain stays exactly `[0,1]`, keeping the asymmetric
    /// out-of-domain extrapolation/clamp behavior stable. An interior point
    /// STOPS at `minimumXSeparation` from whichever neighbor it's
    /// approaching and never reorders past it — which is also what makes a
    /// plain `Int` index safe for a caller to hold for an entire drag.
    static func moving(pointAt index: Int, to location: CGPoint, in points: [ToneCurvePoint], plotRect: CGRect) -> [ToneCurvePoint] {
        guard points.indices.contains(index) else { return points }
        let candidate = normalizedPoint(location, in: plotRect)
        return clamped(pointAt: index, candidateX: candidate.x, candidateY: candidate.y, in: points)
    }

    /// Keyboard-equivalent of `moving`, sharing its exact clamping so mouse
    /// and keyboard can never diverge on where a point is allowed to land.
    /// `dx`/`dy` are deltas in the same normalized units `nudgeStep`/
    /// `coarseNudgeStep` are expressed in.
    static func nudged(pointAt index: Int, dx: Double, dy: Double, in points: [ToneCurvePoint]) -> [ToneCurvePoint] {
        guard points.indices.contains(index) else { return points }
        let point = points[index]
        return clamped(pointAt: index, candidateX: point.x + dx, candidateY: point.y + dy, in: points)
    }

    /// ASSUMES `points` already satisfies the minimum-separation invariant
    /// between `index`'s neighbors — true for anything `moving`/`nudged`
    /// themselves ever produce, but not structurally guaranteed for a
    /// hand-authored sidecar. If a corrupt curve ever violated it
    /// (`rightX - leftX < 2 * minimumXSeparation`), `min(max(c, lo), hi)`
    /// with `lo > hi` returns `hi`, which can push this point BEFORE its
    /// left neighbor in value while its array position stays unchanged —
    /// silently out of x-sorted order. Not corrected here: the failure
    /// mode is graceful, not a crash — `MonotoneToneCurve.init?` rejects
    /// non-increasing x and renders identity, and `curveStrokePath`
    /// mirrors that by drawing nothing — so this is flagged rather than
    /// defended against a second time.
    private static func clamped(
        pointAt index: Int, candidateX: Double, candidateY: Double, in points: [ToneCurvePoint]
    ) -> [ToneCurvePoint] {
        var result = points
        let isEndpoint = index == 0 || index == points.count - 1
        var newX = points[index].x
        if !isEndpoint {
            let leftX = points[index - 1].x
            let rightX = points[index + 1].x
            newX = min(max(candidateX, leftX + minimumXSeparation), rightX - minimumXSeparation)
        }
        let newY = min(max(candidateY, 0), 1)
        result[index] = ToneCurvePoint(x: newX, y: newY)
        return result
    }

    /// Removes the point at `index` — INTERIOR ONLY: a request to remove
    /// either endpoint (index 0 or the last index) is refused, matching
    /// this feature's other two delete routes (Option-click, the "Delete
    /// Point" button all share this one function, so all three are refused
    /// identically rather than needing to agree by convention).
    ///
    /// Collapses back to `[]` when removal leaves exactly the two DEFAULT
    /// endpoints — `(0,0)` and `(1,1)`, i.e. exact identity — restoring the
    /// canonical "no curve at all" representation rather than leaving an
    /// indistinguishable-when-rendered 2-point stand-in. If either endpoint
    /// was itself dragged away from its default, the result is a genuine
    /// 2-point line and is kept as-is — that is real user-authored state,
    /// not an artifact to clean up.
    static func removing(pointAt index: Int, in points: [ToneCurvePoint]) -> [ToneCurvePoint] {
        guard points.indices.contains(index), index != 0, index != points.count - 1 else { return points }
        var result = points
        result.remove(at: index)
        if result.count == 2, result[0] == ToneCurvePoint(x: 0, y: 0), result[1] == ToneCurvePoint(x: 1, y: 1) {
            return []
        }
        return result
    }

    /// Clamps a stored selection index to what's still valid for `points` —
    /// points carry no id (unlike masks; see `EditState.toneCurvePoints`'
    /// own doc comment for why), so a stored `Int` can be invalidated out
    /// from under it by Undo/Redo/Revert/a preset apply shrinking the
    /// array. Every read of a selection must go through this rather than
    /// trust the stored value directly.
    static func validated(_ index: Int?, in points: [ToneCurvePoint]) -> Int? {
        guard let index, points.indices.contains(index) else { return nil }
        return index
    }
}
