import SwiftUI

/// Curves v2 slice 2B — the interactive point-curve canvas. Lives entirely
/// inside `AdjustTabView`'s sidebar (a new "Curve" section), NOT on the
/// image pane — unlike every other point-placement feature in this app
/// (WB eyedropper, Red-Eye, mask overlays), a tone curve has no on-image
/// spatial meaning, so there is no `ContentView` overlay/`canZoom`
/// interaction to wire up here at all.
///
/// Square canvas (`.aspectRatio(1, contentMode: .fit)`) — a short, wide
/// strip would render a 45° line as a shallow few degrees, making slope
/// unreadable. Layers, back to front: chrome, the histogram at reduced
/// opacity (`HistogramBars`, NOT `HistogramView` — this needs the bare
/// drawing with its own opacity/inset, not `HistogramView`'s own frame/
/// background/corner-radius chrome), grid + dashed diagonal reference +
/// curve stroke (one `Canvas`, since none of those need `HistogramBars`'
/// own sticky-blend-mode caveat), handles (`.allowsHitTesting(false)` —
/// purely visual), then one `Color.clear` capture layer doing all the real
/// hit-testing arithmetic via `ToneCurveEditing` — the same layering
/// `MaskOverlayView`/`RedEyeOverlayView` already use, because a per-handle
/// gesture can't distinguish "click empty space to add" from "miss".
///
/// Curves v2 slice 3 made this view render whichever of the app's four
/// curves its `points`/`selectedIndex` bindings currently name — the only
/// channel-aware things it does are the stroke tint, the histogram
/// backdrop, and the accessibility label (all three derived from the one
/// `channel` parameter); every editing operation still goes through
/// `ToneCurveEditing`'s channel-agnostic array functions unchanged. Its
/// caller (`AdjustTabView.curveSection`) instantiates it with `.id(channel)`
/// — see that call site's own doc comment for why that is load-bearing for
/// this view's internal drag/focus state, not decoration.
struct ToneCurveEditorView: View {
    @Binding var points: [ToneCurvePoint]
    @Binding var selectedIndex: Int?
    let histogramData: HistogramData
    /// Curves v2 slice 3: which of the four curves `points`/`selectedIndex`
    /// currently name. This view has no channel LOGIC of its own — it only
    /// derives three presentation facts from this one token (the stroke
    /// tint, the histogram backdrop, the accessibility label) rather than
    /// taking three separate, independently-settable parameters that could
    /// disagree with each other (e.g. a red tint paired with a green
    /// label) with no call site that would ever want that. The caller
    /// (`AdjustTabView.curveSection`) is also responsible for giving this
    /// view a distinct identity per channel via `.id(channel)` — see that
    /// call site's own doc comment for why that is load-bearing, not
    /// decoration, for the `@State`/`@FocusState` this view owns below.
    let channel: ToneCurveChannel

    /// Inset between the canvas's own bounds and `plotRect`, so the corner
    /// handles at (0,0)/(1,1) aren't half-clipped by the view's edge.
    private static let canvasInset: CGFloat = 10
    /// How far outside `plotRect` a drag must release before the dragged
    /// point is deleted — generous on purpose, so releasing near the edge
    /// (easy to do by accident while placing an endpoint-adjacent point)
    /// never reads as "drag it away to delete."
    private static let deleteMargin: CGFloat = 24

    @FocusState private var isFocused: Bool
    /// The point index currently being tracked by an in-progress drag —
    /// distinct from `selectedIndex` (which persists after the drag ends
    /// and drives the detail readout). `nil` between gestures.
    @State private var draggedPointIndex: Int?
    /// The current gesture's `startLocation`, constant for its whole
    /// lifetime — reviewer-caught: without this, a `draggedPointIndex` left
    /// behind by a gesture whose `onEnded` never fires (e.g. cancelled by
    /// the enclosing `ScrollView`) would silently apply to a LATER,
    /// unrelated gesture, teleporting whatever point that stale index names
    /// to wherever the next click happens to land. Comparing this against
    /// each callback's own `startLocation` makes a stale index
    /// self-healing without needing any new gesture-cancellation API.
    ///
    /// Not an unconditional guarantee: if a skipped `onEnded` is followed
    /// by a next mouse-down at EXACTLY the same pixel, this comparison
    /// can't tell the two gestures apart and the stale state survives.
    /// Measure-zero in practice (it needs both a dropped `onEnded` and a
    /// pixel-identical restart), not fixed here.
    @State private var dragStartLocation: CGPoint?
    /// Reviewer-caught (round 2): the option-delete branch below
    /// deliberately never sets `draggedPointIndex`, on the theory that
    /// later callbacks of the same still-held gesture would then "fall
    /// through to the no-op miss path." That claim was wrong — `points`
    /// shrinks after the delete, so a LATER callback re-runs the whole
    /// first-callback branch against the shorter array and, if another
    /// point is now within `hitTestThreshold` of the still-constant
    /// `startLocation` (genuinely reachable: two points can legally sit as
    /// close as `minimumXSeparation`, well inside that threshold), deletes
    /// it too — one option-click on a cluster could delete several points.
    /// This flag makes "the discrete action already fired for this
    /// gesture" its own explicit state, independent of both
    /// `draggedPointIndex` (which tracks an ACTIVE drag, not "nothing left
    /// to do") and `dragStartLocation` (which the miss/add-refused paths
    /// also legitimately re-enter with the same value).
    @State private var didConsumeGestureAsDiscreteAction = false

    private var validatedSelection: Int? { ToneCurveEditing.validated(selectedIndex, in: points) }

    private var isGeometryFinite: Bool {
        points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    var body: some View {
        Group {
            if isGeometryFinite {
                canvas
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(minHeight: 140, maxHeight: 260)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .focusable()
        .focused($isFocused)
        .onKeyPress { handleKeyPress($0) }
        .accessibilityElement()
        .accessibilityLabel(accessibilityChannelLabel)
        .accessibilityValue(Text(accessibilityValueText))
        .accessibilityAdjustableAction { direction in
            guard let index = validatedSelection else { return }
            switch direction {
            case .increment:
                points = ToneCurveEditing.nudged(pointAt: index, dx: 0, dy: ToneCurveEditing.nudgeStep, in: points)
            case .decrement:
                points = ToneCurveEditing.nudged(pointAt: index, dx: 0, dy: -ToneCurveEditing.nudgeStep, in: points)
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: Text("Next Point")) { selectAdjacent(1) }
        .accessibilityAction(named: Text("Previous Point")) { selectAdjacent(-1) }
        .accessibilityAction(named: Text("Delete Selected Point")) { deleteSelected() }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let plotRect = CGRect(
                x: Self.canvasInset, y: Self.canvasInset,
                width: max(proxy.size.width - 2 * Self.canvasInset, 0),
                height: max(proxy.size.height - 2 * Self.canvasInset, 0)
            )
            ZStack {
                HistogramBars(data: histogramData, channels: channel.histogramOverlay)
                    .opacity(0.45)
                    .padding(Self.canvasInset)
                Canvas { context, _ in draw(into: context, plotRect: plotRect) }
                handles(plotRect: plotRect)
                    .allowsHitTesting(false)
                captureLayer(plotRect: plotRect)
            }
        }
    }

    // MARK: - Drawing

    private func draw(into context: GraphicsContext, plotRect: CGRect) {
        var grid = Path()
        for i in 1...2 {
            let fx = plotRect.minX + plotRect.width * CGFloat(i) / 3
            grid.move(to: CGPoint(x: fx, y: plotRect.minY))
            grid.addLine(to: CGPoint(x: fx, y: plotRect.maxY))
            let fy = plotRect.minY + plotRect.height * CGFloat(i) / 3
            grid.move(to: CGPoint(x: plotRect.minX, y: fy))
            grid.addLine(to: CGPoint(x: plotRect.maxX, y: fy))
        }
        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)

        var diagonal = Path()
        diagonal.move(to: ToneCurveEditing.screenPoint(ToneCurvePoint(x: 0, y: 0), in: plotRect))
        diagonal.addLine(to: ToneCurveEditing.screenPoint(ToneCurvePoint(x: 1, y: 1), in: plotRect))
        context.stroke(diagonal, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        guard let curve = curveStrokePath(in: plotRect) else { return }
        // Black-under-tint, the same two-pass legibility idiom
        // `BrushMaskOverlayView.centerLine`/`MaskOverlayView` already use.
        // The top pass is `channel.strokeColor` (Curves v2 slice 3) —
        // `.white` for `.composite`, so this pass is byte-identical to the
        // pre-slice-3 rendering for that case (a structural fact about the
        // code, not a measurement).
        context.stroke(curve, with: .color(.black.opacity(0.6)), lineWidth: 3)
        context.stroke(curve, with: .color(channel.strokeColor), lineWidth: 1.5)
    }

    /// Sampled from `MonotoneToneCurve`'s IN-DOMAIN evaluator
    /// (`curveValue(atEncoded:)`), never the encode/decode-wrapped
    /// `value(at:)` — the editor's x is already in the encoded domain (see
    /// `ToneCurvePoint`'s own doc comment), so routing through the sRGB
    /// wrapper here would plot the wrong curve. Endpoints are always
    /// exactly x=0/x=1 (enforced by `ToneCurveEditing`'s own invariants),
    /// so sampling only 0...1 never needs the evaluator's out-of-domain
    /// clamp/extrapolation branches — those only matter off-canvas.
    private func curveStrokePath(in plotRect: CGRect) -> Path? {
        guard let curve = MonotoneToneCurve(points: points) else { return nil }
        let sampleCount = 64
        var path = Path()
        for i in 0...sampleCount {
            let x = Double(i) / Double(sampleCount)
            let y = curve.curveValue(atEncoded: x)
            // Same non-finite guard every mask overlay carries: a hand-
            // edited sidecar's NaN must not reach `Path` directly.
            guard y.isFinite else { return nil }
            let screen = ToneCurveEditing.screenPoint(ToneCurvePoint(x: x, y: y), in: plotRect)
            if i == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        return path
    }

    /// Deliberately NOT tinted by `channel` (unlike the curve stroke and
    /// histogram backdrop) — handle color here encodes SELECTION
    /// (`Theme.accent` when selected, `.white` otherwise), and
    /// overloading it with channel identity too would leave nothing left
    /// to show selection with. It would also actively hurt legibility in
    /// the one case it would matter most: `Theme.accent` (this app's
    /// own blue accent) over a pure-blue curve stroke and blue
    /// histogram overlay is the worst-contrast combination this feature
    /// has. The channel is already unambiguous from the picker, the curve
    /// stroke, the histogram tint, and the accessibility label — a fifth,
    /// redundant signal here would cost contrast for no new information.
    private func handles(plotRect: CGRect) -> some View {
        ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                let isSelected = index == validatedSelection
                let diameter: CGFloat = isSelected ? 12 : 8
                Circle()
                    .fill(isSelected ? Theme.accent : Color.white)
                    .frame(width: diameter, height: diameter)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                    .position(ToneCurveEditing.screenPoint(point, in: plotRect))
            }
        }
    }

    // MARK: - Interaction

    /// ONE `DragGesture`, not a `SpatialTapGesture` + drag composed with
    /// `.exclusively(before:)` — that composition was tried first and
    /// reviewer-caught as fragile: a `minimumDistance: 0` drag recognizes
    /// at mouse-DOWN, so in practice its `onChanged` always fires before
    /// an option-tap could ever "win" the exclusivity on mouse-up,
    /// regardless of which gesture was declared first. That let an
    /// option-click over empty space silently ADD a point (via this
    /// gesture's own miss path) that the tap then immediately deleted —
    /// a phantom add/delete pair firing a real undo step and sidecar
    /// save — and could leave `draggedPointIndex` set if the drag's own
    /// `onEnded` was ever skipped once the tap "won," corrupting the NEXT
    /// unrelated gesture. Checking the option flag directly inside this
    /// single gesture removes the race instead of arbitrating it.
    ///
    /// Double-click is deliberately NOT handled here or anywhere else: a
    /// `TapGesture(count: 2)` composed with a `minimumDistance: 0` drag is
    /// exactly the gesture-arbitration territory this rewrite moved away
    /// from, and three other delete routes (option-click, drag-off-canvas,
    /// the button) already exist without it.
    private func captureLayer(plotRect: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { onDragChanged($0, plotRect: plotRect) }
                    .onEnded { onDragEnded($0, plotRect: plotRect) }
            )
    }

    private func onDragChanged(_ value: DragGesture.Value, plotRect: CGRect) {
        // Self-healing: see `dragStartLocation`'s own doc comment. A
        // mismatch means this is a NEW gesture and any state left over
        // from a previous one (a stale `draggedPointIndex`, or a discrete
        // action already consumed) must not apply to it.
        if dragStartLocation != value.startLocation {
            draggedPointIndex = nil
            didConsumeGestureAsDiscreteAction = false
        }

        // The option-delete branch below is a ONE-TIME discrete action,
        // not a drag — it deliberately never sets `draggedPointIndex`, so
        // without this flag, a LATER callback of the SAME still-held
        // gesture would re-run this whole branch against the now-shorter
        // `points` and could delete a SECOND point that happened to be
        // within `hitTestThreshold` of the same constant `startLocation`.
        guard !didConsumeGestureAsDiscreteAction else { return }

        guard let index = draggedPointIndex else {
            dragStartLocation = value.startLocation
            let isOptionHeld = NSEvent.modifierFlags.contains(.option)

            if let hit = ToneCurveEditing.nearestPointIndex(to: value.startLocation, in: points, plotRect: plotRect) {
                if isOptionHeld {
                    didConsumeGestureAsDiscreteAction = true
                    deletePoint(at: hit)
                    return
                }
                // Hit -> select only, WRITE NOTHING (a bare click must not
                // fire a sidecar save, histogram render, and undo commit).
                draggedPointIndex = hit
                selectedIndex = hit
                return
            }
            // Miss. An option-click over empty space is a no-op — nothing
            // to delete — rather than adding a point that would then look
            // exactly like a misfired delete. Also marked consumed, so a
            // small mouse drift under a still-held option key can't then
            // wander onto a real point and delete it on a later callback.
            guard !isOptionHeld else {
                didConsumeGestureAsDiscreteAction = true
                return
            }
            let (next, insertedIndex) = ToneCurveEditing.adding(value.startLocation, to: points, plotRect: plotRect)
            guard let insertedIndex else { return }
            points = next
            draggedPointIndex = insertedIndex
            selectedIndex = insertedIndex
            return
        }
        let moved = ToneCurveEditing.moving(pointAt: index, to: value.location, in: points, plotRect: plotRect)
        if moved != points {
            points = moved
        }
    }

    /// Delete-on-release-outside-the-margin: dragging a point away from the
    /// canvas and releasing there deletes it (dragging back in first
    /// cancels, since only the RELEASE location is checked). Guarded by
    /// `dragStartLocation` too, matching `onDragChanged`'s own self-healing
    /// check — an `onEnded` for a gesture whose `onChanged` was never seen
    /// (possible if the very first callback landed on the option-delete
    /// path above, which never sets `draggedPointIndex`) must not act on
    /// whatever index happened to be left over from an earlier gesture.
    private func onDragEnded(_ value: DragGesture.Value, plotRect: CGRect) {
        defer {
            draggedPointIndex = nil
            dragStartLocation = nil
            didConsumeGestureAsDiscreteAction = false
        }
        guard let index = draggedPointIndex, dragStartLocation == value.startLocation else { return }
        let deleteZone = plotRect.insetBy(dx: -Self.deleteMargin, dy: -Self.deleteMargin)
        guard !deleteZone.contains(value.location) else { return }
        deletePoint(at: index)
    }

    /// Shared by both delete-via-drag routes (option-click, drag off the
    /// canvas) — NOT by `deleteSelected()`, which always deletes the
    /// SELECTED point itself and so never needs the shift below.
    /// Reviewer-caught: deleting a point BELOW the current selection
    /// shifts every later array index down by one, so a bare
    /// `if selectedIndex == index { selectedIndex = nil }` would silently
    /// leave `selectedIndex` pointing at a different, still-in-range
    /// point — the readout, handle highlight, and "Delete Point"
    /// button's enabled state would all retarget to that neighbor.
    private func deletePoint(at index: Int) {
        let before = points
        points = ToneCurveEditing.removing(pointAt: index, in: points)
        // `removing` refuses an endpoint (a no-op, `points` unchanged) —
        // guard against also clearing/shifting the selection for a delete
        // that didn't actually happen.
        guard points != before else { return }
        if selectedIndex == index {
            selectedIndex = nil
        } else if let selected = selectedIndex, selected > index {
            selectedIndex = selected - 1
        }
    }

    // MARK: - Keyboard

    /// Mirrors `ContentView.handleImagePaneKeyPress`'s own shape: bail on
    /// any semantic modifier, `.ignored` for anything unhandled so Tab
    /// still moves focus on. Ships as a real feature, not a logged
    /// accessibility gap — see this type's header doc for why a curve
    /// point's two degrees of freedom make nudging worth building, unlike
    /// `BrushMaskOverlayView`'s stroke (an arbitrary polyline nudging
    /// doesn't generalize to).
    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let semanticModifiers: EventModifiers = [.command, .option, .control]
        guard keyPress.modifiers.isDisjoint(with: semanticModifiers) else { return .ignored }

        let step = keyPress.modifiers.contains(.shift) ? ToneCurveEditing.coarseNudgeStep : ToneCurveEditing.nudgeStep

        switch keyPress.key {
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard let index = validatedSelection else { return .ignored }
            let dx: Double = keyPress.key == .leftArrow ? -step : (keyPress.key == .rightArrow ? step : 0)
            let dy: Double = keyPress.key == .upArrow ? step : (keyPress.key == .downArrow ? -step : 0)
            points = ToneCurveEditing.nudged(pointAt: index, dx: dx, dy: dy, in: points)
            return .handled
        case "[":
            selectAdjacent(-1)
            return .handled
        case "]":
            selectAdjacent(1)
            return .handled
        case .delete, .deleteForward:
            // `.handled` only when a point was actually removed — nothing
            // selected (or the selection was an endpoint, which
            // `deleteSelected()` also refuses) should read as an
            // unhandled key, not a silently-swallowed one.
            return deleteSelected() ? .handled : .ignored
        case .escape:
            // Always `.handled`, even when nothing was selected: harmless
            // here, since this canvas's own `FocusState` is mutually
            // exclusive with the image pane's — Escape can never be
            // "stolen" from that pane's own disarm chain, because the two
            // views can't hold keyboard focus at the same time.
            selectedIndex = nil
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Selection / accessibility helpers

    /// Steps the selection to the next/previous point, wrapping into range
    /// from "nothing selected" rather than requiring a first arrow press to
    /// merely establish a selection — the VoiceOver rotor equivalent of
    /// `[`/`]`.
    private func selectAdjacent(_ delta: Int) {
        guard !points.isEmpty else { return }
        let current = validatedSelection ?? (delta > 0 ? -1 : points.count)
        let next = current + delta
        guard points.indices.contains(next) else { return }
        selectedIndex = next
    }

    /// Returns whether a point was actually removed — always the SELECTED
    /// point itself (never a different index), so unlike `deletePoint(at:)`
    /// this never needs to shift `selectedIndex` for a neighbor, only
    /// clear it. Still checks `points != before`: `removing` refuses an
    /// endpoint, and a selected endpoint is reachable via `[`/`]` cycling.
    @discardableResult
    private func deleteSelected() -> Bool {
        guard let index = validatedSelection else { return false }
        let before = points
        points = ToneCurveEditing.removing(pointAt: index, in: points)
        guard points != before else { return false }
        selectedIndex = nil
        return true
    }

    /// `.composite`'s string is kept byte-identical to this view's
    /// pre-slice-3 static label — slice 2B's live-verified VoiceOver custom
    /// actions were checked against that exact string. NOT "Tone curve
    /// editor, RGB channel": RGB is this feature's name for the composite
    /// (all-channels-together) curve, not a fourth channel, and reading it
    /// as one would be actively confusing.
    private var accessibilityChannelLabel: String {
        channel == .composite ? "Tone curve editor" : "Tone curve editor, \(channel.rawValue) channel"
    }

    /// Reviewer-caught crash class (the same one `MaskDetailView`'s own
    /// tone-percent readout was caught with once already): this string is
    /// built by the OUTER `Group`'s `.accessibilityValue`, which sits
    /// ABOVE the `if isGeometryFinite` branch that guards `canvas` — so a
    /// hand-edited sidecar's `NaN`/astronomical coordinate reaches this
    /// property regardless of whether the canvas itself renders anything,
    /// and `isGeometryFinite` only checks `isFinite`, not magnitude. Both
    /// guarded here directly: `Int(Double.nan)` and `Int(1e300)` both trap,
    /// so a finite check alone is not enough.
    private var accessibilityValueText: String {
        guard let index = validatedSelection else {
            return points.isEmpty ? "No curve" : "No point selected"
        }
        let point = points[index]
        guard point.x.isFinite, point.y.isFinite else {
            return "Point \(index + 1) of \(points.count). Value unavailable."
        }
        let clampedX = min(max(point.x, -1_000_000), 1_000_000)
        let clampedY = min(max(point.y, -1_000_000), 1_000_000)
        return "Point \(index + 1) of \(points.count). Input \(Int(round(clampedX * 100))) percent, "
            + "output \(Int(round(clampedY * 100))) percent."
    }
}
