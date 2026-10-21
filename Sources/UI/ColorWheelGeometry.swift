import CoreGraphics

/// Pure screen-space math for Color Grading Slice B's wheel control — the
/// UI-side polar↔Cartesian conversion `ColorGradingWheelView` needs, the
/// same split `ToneCurveEditing` already establishes for the curve editor.
/// `import CoreGraphics` only, no SwiftUI — the strict convention shared by
/// `ToneCurveEditing`/`RedEyeHitTest`/`MaskGeometry`/`CropAspectMath`, so
/// this arithmetic gets direct XCTest coverage instead of being eyeballed
/// through a gesture.
///
/// ANGLE CONVENTION: 0° is at the wheel's right edge (3 o'clock), increasing
/// COUNTERCLOCKWISE as viewed on screen — the standard mathematical
/// convention, achieved on screen's Y-DOWN coordinate space by negating the
/// sine term (`y = center.y - radius * sin(θ)`). This must visually agree
/// with whatever hue gradient `ColorGradingWheelView` paints behind the
/// puck — verified live, not just asserted here (see the Slice B plan's own
/// Verification section).
///
/// RADIUS CONVENTION: `saturation` is the puck's radial distance from
/// center as a FRACTION of `wheelRadius(_:)`, matching `EditState.
/// shadowSaturation`'s own doc comment ("the wheel puck's radial distance
/// from center"). Dragging outside the circle clamps the RADIUS to 1 while
/// PRESERVING the angle (a true polar clamp), not an independent x/y clamp
/// — those produce different results for the same out-of-circle point.
enum ColorWheelGeometry {
    // MARK: - Keyboard / VoiceOver stepping (D20)

    /// Default step sizes for the wheel's arrow keys and accessibility actions.
    static let hueStepDegrees: Double = 10
    static let saturationStep: Double = 0.05

    /// Steps the wheel's value without a pointer. Hue wraps into (-180, 180] (`polarValue`'s range; -180 and
    /// 180 are the same direction and are reported as 180); Saturation clamps to 0...1 (residue below 1e-9 from
    /// repeated float steps counts as 0). IDENTITY RULE: whenever the resulting Saturation is 0, Hue is EXACTLY 0,
    /// the same snap `polarValue` makes at the centre, because `isColorGradingRangeAtIdentity` and
    /// `isAdjustTabAtIdentity` read identity as Hue == 0 && Saturation == 0. A Hue step on a wheel whose
    /// Saturation is 0 therefore changes nothing (a hue with no saturation is not a state this wheel has).
    static func stepped(
        hue: Double, saturation: Double, hueDelta: Double = 0, saturationDelta: Double = 0
    ) -> (hue: Double, saturation: Double) {
        guard hue.isFinite, saturation.isFinite else { return (0, 0) }
        var newSaturation = min(max(saturation + saturationDelta, 0), 1)
        if newSaturation < 1e-9 { newSaturation = 0 }
        guard newSaturation > 0 else { return (0, 0) }
        return (wrappedHue(hue + hueDelta), newSaturation)
    }

    /// `stepped`, or nil when the step changes nothing (Hue at Saturation 0, Down at 0, Up at 1), so callers
    /// can skip the write instead of dirtying the edit state with an identical value.
    static func steppedIfChanged(
        hue: Double, saturation: Double, hueDelta: Double = 0, saturationDelta: Double = 0
    ) -> (hue: Double, saturation: Double)? {
        let next = stepped(hue: hue, saturation: saturation, hueDelta: hueDelta, saturationDelta: saturationDelta)
        return next.hue == hue && next.saturation == saturation ? nil : next
    }

    /// `degrees` wrapped into (-180, 180].
    static func wrappedHue(_ degrees: Double) -> Double {
        var wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped <= -180 { wrapped += 360 }
        return wrapped
    }

    /// VoiceOver value, e.g. "Hue +137°, Saturation 42%".
    static func accessibilityValue(hue: Double, saturation: Double) -> String {
        String(format: "Hue %+.0f°, Saturation %.0f%%", hue, saturation * 100)
    }

    /// Inset between the wheel's outer edge and the puck's own visual
    /// radius, so a puck at full Saturation (1) doesn't render half-clipped
    /// outside the control's bounds — the same role `ToneCurveEditorView`'s
    /// `canvasInset` plays for that view's plot rect.
    static let puckInset: CGFloat = 8

    /// Half the wheel rect's smaller dimension, inset by `puckInset`. `0`
    /// (not negative) for a degenerate/too-small rect — every function
    /// below guards on this rather than dividing by a non-positive radius.
    static func wheelRadius(_ rect: CGRect) -> CGFloat {
        max(0, min(rect.width, rect.height) / 2 - puckInset)
    }

    /// Hue/Saturation -> screen point (the puck's position). `saturation`
    /// is clamped to 0...1 here defensively — `EditState`'s own fields
    /// aren't runtime-clamped (see `EditPipeline.applyColorGrading`'s own
    /// clamp at render time), so a hand-edited sidecar's out-of-range value
    /// must still resolve to an on-wheel position, not an off-screen one.
    static func screenPoint(hue: Double, saturation: Double, in rect: CGRect) -> CGPoint {
        let radius = wheelRadius(rect) * CGFloat(min(max(saturation, 0), 1))
        let angleRadians = hue * .pi / 180
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return CGPoint(
            x: center.x + radius * CGFloat(cos(angleRadians)),
            y: center.y - radius * CGFloat(sin(angleRadians))
        )
    }

    /// Exact inverse of `screenPoint` (up to the radial clamp described
    /// above). Returns `(hue: 0, saturation: 0)` for a degenerate rect (no
    /// radius to divide by) — a sane default, not NaN, matching
    /// `ToneCurveEditing.normalizedPoint`'s own degenerate-rect handling.
    ///
    /// **Both hue AND saturation snap to exactly `0` whenever the location
    /// is within `centerSnapSaturationThreshold` of the wheel's center**,
    /// rather than returning whatever `atan2(~0, ~0)` happens to produce or
    /// a non-zero near-epsilon saturation. This is load-bearing, not
    /// cosmetic: `AdjustTabView.isAdjustTabAtIdentity` checks Hue `== 0`
    /// AND Saturation `== 0` as part of its "every field at its literal
    /// default" identity contract (see `EditState.shadowHue`'s own doc
    /// comment). The threshold is a FRACTION of the wheel's radius, not an
    /// absolute point distance, because it must scale across this
    /// control's 140-220pt frame range — a fixed point-distance epsilon
    /// tight enough not to bite real drags is a stationary target as the
    /// radius (`wheelRadius`, ~62-102pt over that range) changes size.
    static func polarValue(at location: CGPoint, in rect: CGRect) -> (hue: Double, saturation: Double) {
        let radius = wheelRadius(rect)
        guard radius > 0 else { return (0, 0) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = hypot(dx, dy)
        let saturation = min(Double(distance / radius), 1)
        guard saturation > centerSnapSaturationThreshold else { return (0, 0) }
        let angleRadians = atan2(Double(-dy), Double(dx))
        return (angleRadians * 180 / .pi, saturation)
    }

    /// A puck landing within this fraction of the wheel's radius from
    /// center snaps to the exact identity state (see `polarValue`'s own
    /// doc comment on why both fields must snap together). 2% keeps the
    /// dead zone visually imperceptible (roughly 1-2pt at every frame size
    /// this control actually renders at) while comfortably covering where
    /// a real cursor/finger lands when a user is aiming for dead center —
    /// unlike the previous absolute 1e-6 POINT-distance epsilon, which a
    /// real drag essentially never triggered.
    private static let centerSnapSaturationThreshold: Double = 0.02

    /// Hue degrees (this type's own 0°=right/CCW convention) -> the
    /// fraction SwiftUI's `AngularGradient(gradient:center:)` convenience
    /// initializer expects as a stop `location`, so `ColorGradingWheelView`'s
    /// painted hue wheel lines up with the puck position `screenPoint`
    /// computes for the same hue. Pulled out of that view (which has no
    /// XCTest coverage of its own, per this codebase's "pure geometry gets
    /// direct unit tests, not eyeballed through a gesture" convention) after
    /// a first draft's `AngularGradient` convention assumption shipped
    /// backwards and was reviewer-caught before ever landing.
    ///
    /// Derived from SwiftUI's documented behavior, then LIVE-VERIFIED on
    /// screen (2026-09-29, Release build, scratch fixture): red painted at
    /// the right edge, yellow-green at the top, cyan at the left, blue at the
    /// lower left, magenta at the lower right; a click at the top edge read
    /// approximately H +90° (caption partly clipped) and one at the left edge
    /// read H 180° / S 100%, each with the
    /// puck sitting on the matching painted color. That convenience
    /// initializer is
    /// `startAngle: .zero, endAngle: .degrees(360)`,
    /// and SwiftUI's `Angle` zero points along +x (3 o'clock, screen right
    /// edge) sweeping CLOCKWISE with increasing angle in this y-down view
    /// space. So fraction 0 is this type's own theta=0 (right edge, hue 0),
    /// and fraction increases CLOCKWISE — the OPPOSITE rotational sense
    /// from this type's theta, which increases counterclockwise. Derivation:
    /// clockwise-from-right by fraction `f` reaches the same screen angle as
    /// this type's counterclockwise `-f*360` degrees, so `theta = -f*360`
    /// (mod 360) and therefore `f = wrap(-theta) / 360`.
    static func angularGradientFraction(forHueDegrees hueDegrees: Double) -> Double {
        let wrapped = (-hueDegrees).truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) / 360
    }
}
