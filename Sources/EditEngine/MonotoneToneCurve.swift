import CoreGraphics
import Foundation

/// The Swift twin of `Sources/Rendering/Shaders/PointToneCurve.cikernel` —
/// the monotone-cubic solve behind Curves v2's user-placed point curve.
///
/// WHY THIS IS A SEPARATE TYPE FROM `ToneCurveSpline`, AND NOT A MODE ON IT.
/// The obvious-looking alternative — `enum Mode { case natural, monotone }`
/// on `ToneCurveSpline` — was considered and rejected. That type's whole doc
/// comment is a reverse-engineering record of `CIToneCurve`'s exact
/// behaviour, and its byte-exactness against ~70 shipped assertions is why
/// every saved sidecar still renders correctly. A mode parameter would make
/// "which end condition does the byte-exact parametric layer use?" a runtime
/// question, one flag flip away from changing how every shipped edit
/// renders. A separate type makes that contract STRUCTURAL: the parametric
/// layer cannot accidentally become monotone, because it does not have the
/// code. The measured numbers back this — slice 1's pre-work fitted monotone
/// cubic at 0.016 error against `CIToneCurve` versus natural cubic's
/// 0.00000, an order of magnitude past this suite's 0.002 tolerance.
///
/// WHY MONOTONE HERE, THEN. The parametric layer's control points come from
/// clamped sliders and can only ever form a gentle S. The user's points are
/// placed freely, and a natural cubic through freely-placed points
/// OVERSHOOTS: the rendered tone response can visibly reverse between two
/// control points, which reads as a rendering bug rather than as a curve.
/// Fritsch-Carlson cannot do that by construction.
///
/// Reference: F. N. Fritsch and R. E. Carlson, "Monotone Piecewise Cubic
/// Interpolation", SIAM Journal on Numerical Analysis 17(2), 1980, 238-246.
///
/// DOMAIN. Control points live in the sRGB-encoded domain, exactly as
/// `ToneCurveSpline`'s do, and `value(at:)` applies the same
/// encode -> curve -> decode sandwich. See `ToneCurvePoint`'s own doc
/// comment: the stage runs INSIDE `applyPerceptualAdjustments`' outer
/// sandwich and encodes again internally, and that second encode is
/// deliberate, matching what the parametric layer next to it does.
struct MonotoneToneCurve {
    /// The kernel passes the curve as fixed-arity `vec4` uniforms, so this
    /// cap is a real rendering limit rather than a soft guideline — see
    /// `PointToneCurve.cikernel`'s header for the argument budget it comes
    /// from. Lightroom's own point curve allows 16; 8 covers realistic
    /// curves, and a future slice can raise it only by changing the kernel.
    static let maximumPointCount = 8

    /// Rejects absurd COORDINATES. A control point slightly outside the
    /// unit square is meaningful (and the editor will not produce one), but
    /// a hand-typed 1e300 has no sane rendering. This is a sanity bound on
    /// position, not a range constraint — deliberately NOT a 0...1 clamp,
    /// which would quietly reintroduce the kind of domain clipping slice 1
    /// removed.
    ///
    /// Note precisely what this does NOT cover: it bounds where a point
    /// sits, not how STEEP the curve between two points is. Slope is
    /// bounded separately, by `minimumXSeparation` below.
    static let maximumMagnitude: Double = 8

    /// The floor on the x-gap between adjacent control points, and the only
    /// thing bounding the curve's SLOPE.
    ///
    /// MEASURED (reviewer-found, on the real compiled kernel, not argued
    /// from the maths): the points (0, 0), (0.5, 0.5), (0.5 + 1e-6, 1.0)
    /// pass an ordering-and-magnitude-only guard and render linear 0.6 as
    /// 2.29e12. That is not NaN and not infinity — the branch structure
    /// confines the enormous tangent to its own degenerate segment — but
    /// "absurdly steep" is still not something this type should hand the
    /// kernel and call sane. The value is far below anything the 2B editor
    /// will produce (it enforces a separation two orders of magnitude
    /// larger), so this guard exists for hand-authored input only.
    static let minimumXSeparation: Double = 1e-4

    let points: [ToneCurvePoint]

    /// One tangent per control point, after the Fritsch-Carlson
    /// monotonicity filter. Solved once here, per slider move — a
    /// `CIColorKernel` cannot and should not run the filter per pixel,
    /// which is the same split `ToneCurveSpline` already uses.
    let tangents: [Double]

    /// The slope the curve extrapolates along above its last control point.
    /// Unlike `ToneCurveSpline`, this is NOT stored separately: a Hermite
    /// tangent IS the derivative, so the end slope is simply the last
    /// tangent and there is nothing that can drift out of sync with the
    /// final segment.
    var endSlope: Double { tangents[tangents.count - 1] }

    /// Fails (returns nil) on anything the kernel could not render sanely.
    /// Callers treat nil as "leave the image alone" — so a malformed
    /// hand-authored curve renders IDENTITY, which is visibly wrong, rather
    /// than silently dropping points, which would be invisibly wrong.
    ///
    /// The floor is TWO points, not `ToneCurveSpline`'s three. That is not
    /// a copy-paste slip: a natural cubic needs an interior point to have a
    /// system to solve, while monotone Hermite through two points is one
    /// segment with both tangents equal to the secant — an exact straight
    /// line.
    ///
    /// The x-separation guard bounds the curve's slope; see
    /// `minimumXSeparation` for the measurement that motivated it. Note it
    /// subsumes the plain strictly-increasing check — a zero or negative
    /// gap fails it too.
    ///
    /// The `isFinite` guard is load-bearing and has no counterpart in
    /// `ToneCurveSpline`. An ordering check written as `x <= previous`
    /// evaluates to `false` for NaN, so a NaN x would PASS an
    /// ordering-only guard and produce NaN pixels. `ToneCurveSpline` is
    /// exposed to that in principle but not in practice (its points come
    /// from clamped sliders); this type takes hand-authored input, so it
    /// checks.
    init?(points: [ToneCurvePoint]) {
        guard points.count >= 2, points.count <= Self.maximumPointCount else { return nil }
        for point in points {
            guard point.x.isFinite, point.y.isFinite else { return nil }
            guard abs(point.x) <= Self.maximumMagnitude, abs(point.y) <= Self.maximumMagnitude else { return nil }
        }
        for i in 1..<points.count where points[i].x - points[i - 1].x < Self.minimumXSeparation { return nil }

        self.points = points
        self.tangents = Self.monotoneTangents(points)
    }

    // MARK: - Fritsch-Carlson

    /// Secant slopes, then averaged interior tangents, then the
    /// monotonicity filter. The filter is what distinguishes this from a
    /// plain Catmull-Rom-ish Hermite: it projects each tangent pair onto
    /// the circle of radius 3 in (alpha, beta) space, which is exactly the
    /// region Fritsch and Carlson prove keeps the segment monotone.
    private static func monotoneTangents(_ points: [ToneCurvePoint]) -> [Double] {
        let n = points.count
        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            secants[i] = (points[i + 1].y - points[i].y) / (points[i + 1].x - points[i].x)
        }

        var m = [Double](repeating: 0, count: n)
        m[0] = secants[0]
        m[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            m[i] = (secants[i - 1] + secants[i]) / 2
        }

        for i in 0..<(n - 1) {
            let d = secants[i]
            if d == 0 {
                // A flat interval must stay flat — otherwise the segment
                // bulges above or below both of its endpoints. This branch
                // also keeps the division below well-defined.
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            var alpha = m[i] / d
            var beta = m[i + 1] / d
            // A tangent opposing its own secant overshoots immediately.
            if alpha < 0 { m[i] = 0; alpha = 0 }
            if beta < 0 { m[i + 1] = 0; beta = 0 }
            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let tau = 3 / magnitude.squareRoot()
                m[i] = tau * alpha * d
                m[i + 1] = tau * beta * d
            }
        }
        return m
    }

    /// One cubic Hermite segment. Twin of `PointToneCurve.cikernel`'s
    /// `hermiteSegment`.
    ///
    /// THE COLLINEARITY IDENTITY, which two things downstream depend on:
    /// if the control points are collinear with slope m, every secant
    /// equals m, so every tangent is m and the filter never fires
    /// (alpha = beta = 1, and 1 + 1 < 9). Substituting y1 = y0 + m*h and
    /// using h00 + h01 == 1 and h01 + h10 + h11 == t identically, this
    /// reduces to y0 + m*(u - x0) — EXACTLY the straight line, in exact
    /// arithmetic. That is why an identity-shaped point list renders exact
    /// identity, and why the kernel's pad-to-8 scheme is provably free
    /// rather than approximate.
    private static func hermiteSegment(
        _ u: Double, x0: Double, x1: Double, y0: Double, y1: Double, m0: Double, m1: Double
    ) -> Double {
        let h = x1 - x0
        let t = (u - x0) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * y0 + h10 * h * m0 + h01 * y1 + h11 * h * m1
    }

    /// The curve evaluated in its OWN (already sRGB-encoded) domain, with no
    /// encode/decode wrapper. This is what an editor plots, and what the
    /// kernel computes; `value(at:)` is this sandwiched between encode and
    /// decode.
    ///
    /// OUT-OF-DOMAIN BEHAVIOUR IS DELIBERATELY ASYMMETRIC, matching
    /// `ToneCurveSpline` exactly:
    /// - ABOVE the last point: linear extrapolation along the curve's own
    ///   end tangent, so highlight headroom created by Exposure survives an
    ///   active curve. C1-continuous by construction.
    /// - BELOW the first point: clamped to its y. The leftmost point is a
    ///   black point; everything below it is meant to be black, and
    ///   extrapolating there would drive values negative.
    ///
    /// One honest consequence, asserted by a test rather than left to be
    /// discovered: Fritsch-Carlson can legitimately clamp the end tangent to
    /// 0 (drag the top two points level), and the extrapolation is then flat,
    /// compressing headroom. That is NOT the v1 defect returning — v1
    /// clamped unconditionally whether or not the user asked; here it
    /// happens only when the user explicitly draws a flat top. Do not
    /// "fix" it by flooring the end tangent: that would break both C1
    /// continuity and the monotonicity guarantee this whole type exists for.
    func curveValue(atEncoded u: Double) -> Double {
        let n = points.count
        if u <= points[0].x { return points[0].y }
        if u >= points[n - 1].x {
            return points[n - 1].y + endSlope * (u - points[n - 1].x)
        }
        var i = 0
        while i < n - 2 && u > points[i + 1].x { i += 1 }
        return Self.hermiteSegment(
            u,
            x0: points[i].x, x1: points[i + 1].x,
            y0: points[i].y, y1: points[i + 1].y,
            m0: tangents[i], m1: tangents[i + 1]
        )
    }

    /// The complete transfer function the kernel implements: encode ->
    /// curve -> decode. Reuses `ToneCurveSpline`'s sRGB helpers rather than
    /// restating them, so the two Swift evaluators cannot drift on the
    /// transfer function even though they differ on the interpolant. (The
    /// kernel restates them, per this project's one-kernel-per-file rule.)
    func value(at v: Double) -> Double {
        ToneCurveSpline.srgbDecode(curveValue(atEncoded: ToneCurveSpline.srgbEncode(v)))
    }

    // MARK: - Kernel packing

    /// The control points padded out to exactly `maximumPointCount`, which
    /// is what lets the kernel be fixed-arity, fully unrolled, and free of
    /// both a point-count uniform and a separate extrapolation branch.
    ///
    /// Each padded point continues along the end tangent, and CARRIES that
    /// tangent. By the collinearity identity in `hermiteSegment`, every
    /// padded segment therefore evaluates to exactly the straight line the
    /// extrapolation rule would have produced — so padding is provably
    /// output-identical, not an approximation. `testPaddingDoesNotChangeTheRenderedResult`
    /// checks that rather than trusting it.
    ///
    /// The 0.25 x-step is arbitrary and nothing depends on its value; any
    /// positive step gives the same curve. It is not a tuned constant.
    ///
    /// Padding happens only here, at render time, AFTER the tangents were
    /// solved on the real points — so it cannot perturb the real solve.
    func paddedForKernel() -> (points: [ToneCurvePoint], tangents: [Double]) {
        var p = points
        var m = tangents
        let slope = endSlope
        var k = 1.0
        while p.count < Self.maximumPointCount {
            let last = points[points.count - 1]
            p.append(ToneCurvePoint(x: last.x + k * 0.25, y: last.y + slope * (k * 0.25)))
            m.append(slope)
            k += 1
        }
        return (p, m)
    }
}
