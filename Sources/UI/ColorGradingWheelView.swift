import SwiftUI

/// Color Grading Slice B — the draggable Hue/Saturation wheel. This app's
/// FIRST continuous-hue rendering UI (confirmed by a fresh grep before this
/// slice: no `AngularGradient`/`RadialGradient`/hue-wheel exists anywhere
/// else in `Sources/UI`). Lives inside `AdjustTabView`'s "Color Grading"
/// section, one instance shared across all 3 tonal ranges via
/// `AdjustTabView.colorGradingSection`'s `.id(panel.selectedColorGradingRange)`
/// — see that call site's own doc comment for why that's PRECAUTIONARY, not
/// load-bearing, today (this view has no persistent `@State`/`@FocusState`
/// for a channel switch to leave stale — unlike `ToneCurveEditorView`'s own
/// `.id(channel)`, which closes a real hazard).
///
/// SIMPLER than `ToneCurveEditorView` in one real structural way, not just
/// smaller: there is no add/delete/multi-point bookkeeping here, only ONE
/// puck that always exists. Every `onChanged` callback writes `hue`/
/// `saturation` directly (`ColorWheelGeometry.polarValue(at:in:)`), so if a
/// gesture's `onEnded` is ever dropped by the enclosing `ScrollView` (the
/// concern that drove `ToneCurveEditorView`'s `dragStartLocation`/
/// `didConsumeGestureAsDiscreteAction` self-heal machinery), there is no
/// stale per-gesture state left behind to corrupt a later gesture — the
/// puck simply stays at its last-written (already correct) position. The
/// SAME `DragGesture(minimumDistance: 0, coordinateSpace: .local)` shape
/// that avoids fighting the ScrollView is still reused, since that part of
/// the precedent is unrelated to the self-heal machinery.
///
/// Rendering is a VISUAL APPROXIMATION of the wheel's real geometry, not
/// calibrated pixel-for-pixel against `ColorGradingTint.rgbDelta`'s actual
/// output — the same "close enough for a swatch, not a promise of exact
/// hue-degree equivalence" disclaimer `SelectiveColorBand.swatchColor`'s
/// own doc comment already establishes for this codebase.
///
/// Keyboard/VoiceOver support for dragging the puck is EXPLICITLY DEFERRED
/// to its own future session — matches this app's own established
/// precedent (the WB eyedropper and Red-Eye placement both shipped
/// pointer-first; see IMPROVEMENTS.md D8/D14 for the shape of that
/// follow-up). The Luminance slider next to this view (a plain
/// `EditSliderRow`) remains a real, fully keyboard/AT-accessible path to
/// that one axis regardless — the same partial-coverage shape D9 already
/// documents for mask overlays.
struct ColorGradingWheelView: View {
    @Binding var hue: Double
    @Binding var saturation: Double

    /// A single fixed value, not a min/max range — see `body`'s own doc
    /// comment on why this control's frame must be unnegotiated. Chosen
    /// between the old range's former 140-220 bounds for comfortable puck
    /// placement. NOT floor-constrained by the sidebar's own minimum
    /// width today — `ContentView`'s `editControls` pane floor is
    /// `minWidth: 360` (raised from 260 in the same bug-fix round this
    /// value shipped in), leaving ~170pt of slack around this circle,
    /// not a tight fit against that floor.
    private static let wheelDiameter: CGFloat = 190

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                wheelBackground(in: rect)
                puck(in: rect)
                    .allowsHitTesting(false)
                captureLayer(in: rect)
            }
        }
        // An EXACT frame, not a min/max range — deliberately NOT
        // `aspectRatio(1, .fit)` plus a flexible width/height range.
        // User-caught symptom: with the old negotiated range, dragging
        // the puck visibly grew the whole sidebar wider while the
        // gesture was active and snapped back once it ended. The
        // WORKING HYPOTHESIS (observed and fixed, but not instrumented
        // or measured — do not read this as a confirmed root cause):
        // `aspectRatio(1, .fit)` alone leaves width under-constrained
        // (`GeometryReader` has no intrinsic size, so width came
        // entirely from whatever the ancestor proposed), and re-running
        // that negotiation on every `DragGesture.onChanged` (i.e. every
        // frame of the drag, since `hue`/`saturation` change that often)
        // may not have converged to a stable size while state was
        // changing that fast. Whatever the exact mechanism, an exact,
        // unnegotiated frame removes the ambiguity entirely: the
        // `GeometryReader` inside is always proposed precisely
        // `wheelDiameter`x`wheelDiameter` regardless of ancestor state,
        // on every frame, drag or not — which is what actually matters.
        .frame(width: Self.wheelDiameter, height: Self.wheelDiameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
        // Applied AFTER the fixed-size clip, not before — this centers the
        // already-circular, already-bounded control within the section's
        // full row width without re-widening the square `Circle()` clips.
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityHidden(true)
    }

    /// `endRadius` is `ColorWheelGeometry.wheelRadius(rect)` — the SAME
    /// radius `screenPoint`/`polarValue` treat as Saturation 1 — not an
    /// arbitrary constant. A mismatched radius here would desaturate (or
    /// fully saturate) the painted wheel at a different radius than where
    /// the puck actually reads Saturation 1, so the swatch under the puck
    /// would never match `ColorGradingTint.rgbDelta`'s actual Saturation
    /// reading at that position.
    private func wheelBackground(in rect: CGRect) -> some View {
        let radius = ColorWheelGeometry.wheelRadius(rect)
        return ZStack {
            AngularGradient(gradient: Gradient(stops: hueGradientStops), center: .center)
            RadialGradient(
                gradient: Gradient(colors: [.white, .white.opacity(0)]),
                center: .center, startRadius: 0, endRadius: radius
            )
        }
    }

    /// Explicit stops built from `ColorWheelGeometry.angularGradientFraction(forHueDegrees:)`
    /// — that function (not this view) owns the geometric convention and
    /// carries this control's own unit tests, per this codebase's "pure
    /// geometry gets direct XCTest coverage, not eyeballed through a
    /// gesture" convention. **Not yet live-verified** — see the Slice B
    /// plan's own Verification section. If the convention assumption is
    /// wrong, the fix is confined to `angularGradientFraction` alone, not
    /// this view's structure.
    ///
    /// An explicit CLOSING stop at location `1.0`, duplicating the first
    /// (lowest-location) stop's color, is required — `AngularGradient`
    /// holds the color of its LAST stop from that stop's location all the
    /// way to `1.0` rather than blending back toward the first stop, so
    /// without this the wedge between the highest sampled hue and the
    /// wrap-around back to hue 0 would render as a flat, hard-edged band
    /// instead of a continuous gradient.
    private var hueGradientStops: [Gradient.Stop] {
        let stops = stride(from: -180.0, to: 180.0, by: 30.0).map { hue in
            Gradient.Stop(
                color: Color(hue: normalizedHueFraction(hue), saturation: 1, brightness: 1),
                location: ColorWheelGeometry.angularGradientFraction(forHueDegrees: hue)
            )
        }.sorted { $0.location < $1.location }
        guard let first = stops.first else { return stops }
        return stops + [Gradient.Stop(color: first.color, location: 1.0)]
    }

    private func normalizedHueFraction(_ hueDegrees: Double) -> Double {
        let wrapped = hueDegrees.truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) / 360
    }

    private func puck(in rect: CGRect) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
            .position(ColorWheelGeometry.screenPoint(hue: hue, saturation: saturation, in: rect))
    }

    private func captureLayer(in rect: CGRect) -> some View {
        Color.clear
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let polar = ColorWheelGeometry.polarValue(at: value.location, in: rect)
                        hue = polar.hue
                        saturation = polar.saturation
                    }
            )
    }
}
