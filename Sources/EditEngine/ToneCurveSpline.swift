import CoreGraphics
import Foundation

/// The Swift twin of `Sources/Rendering/Shaders/ToneCurve.cikernel` — the
/// spline solve that the kernel itself cannot do (a `CIColorKernel` has no
/// way to solve a tridiagonal system per pixel, and there is no reason to:
/// the curve changes once per slider move, not once per pixel).
///
/// This exists because `CIToneCurve` was REPLACED, not wrapped. The reason
/// that replacement is safe — and byte-exact against ~70 shipped assertions
/// across Shadows/Highlights, Black Point, Brilliance and per-mask
/// Shadows/Highlights — is that `CIToneCurve`'s undocumented spline was
/// fully reverse-engineered first (2026-09-17, see PROGRESS.md's
/// "Curves v2 slice 1 — pre-work" section). MEASURED, not assumed:
///
///     CIToneCurve = sRGB-encode
///                   -> NATURAL CUBIC spline (control points live in sRGB space)
///                   -> sRGB-decode
///
/// with max |filter - model| of 3e-7...5e-7 across a 129-sample sweep on five
/// control configurations (shadows +/-1, highlights +1, black point +/-1).
///
/// Note the encode is the filter's OWN, and is a SECOND encode: `applyCurves`
/// is called from inside `applyPerceptualAdjustments`' `encodeToPerceptual`/
/// `decodeToLinear` sandwich, so the values arriving here are already
/// perceptual. That double encode is not a bug to fix — it is exactly what
/// every shipped edit in every sidecar and preset was rendered with, and
/// reproducing it is what makes saved photos render identically.
///
/// OUT-OF-DOMAIN BEHAVIOUR IS DELIBERATELY ASYMMETRIC, and this is the ONE
/// intended behaviour change in the whole replacement:
/// - ABOVE `x4`: linear extrapolation along the spline's own end slope.
///   `CIToneCurve` hard-clamped here (measured: inputs 1.05/1.2/1.5/2.0/4.0
///   all returned exactly 1.0), which is the recorded v1 defect — an active
///   curve collapsed the highlight headroom that Exposure had created, while
///   every other stage in this pipeline preserves it.
/// - BELOW `x0`: still clamped to `y0`, matching `CIToneCurve` exactly.
///   This is NOT an oversight and NOT the same defect. `point0.x` IS the
///   black point: everything below it is meant to be black, and clamping is
///   what makes Black Point actually clip (`testBlackPointDeepClip`).
///   Extrapolating linearly there would send values negative instead.
///
/// While fixing the headroom, a SECOND recorded claim was found to be wrong
/// and has been corrected at its source in `EditPipeline.applyCurves`:
/// v1's doc comment said `CIToneCurve` "extrapolates (does not hard-clamp)
/// inputs just below point0.x", producing a soft black point. It does not —
/// it clamps at both ends. The measured "soft" lift it described (linear
/// 0.01 with black point -1 reading 0.03381 rather than 0) comes from the
/// spline's IN-DOMAIN shape: after the pipeline's encode and the filter's
/// own encode, linear 0.01 arrives at u = 0.349, comfortably inside
/// [0.20, 1]. That number is unchanged by this rewrite.
struct ToneCurveSpline {
    /// Control points, in the spline's own sRGB-encoded space. Strictly
    /// increasing in x.
    let points: [CGPoint]

    /// Natural-cubic second derivatives, one per control point. "Natural"
    /// means the second derivative is pinned to zero at both ends, so
    /// `secondDerivatives.first` and `.last` are always exactly 0 — the
    /// kernel relies on being handed them rather than assuming it, so a
    /// future clamped/periodic end condition would need no kernel change.
    let secondDerivatives: [Double]

    /// The spline's own derivative at the LAST control point, which the
    /// kernel extrapolates along above `x4`. Computed here rather than in
    /// the kernel so this type's tests cover it, and so the extrapolation is
    /// guaranteed C1-continuous with the final segment rather than merely
    /// close to it.
    let endSlope: Double

    /// `points` as Doubles, built once: `splineValue` runs hundreds of times per monotonicity check and must not allocate on every call.
    private let xs: [Double]
    private let ys: [Double]

    /// Fails (returns nil) on fewer than 3 points or non-increasing x —
    /// a degenerate solve would divide by a zero interval. Callers treat
    /// nil as "leave the image alone", never as "carry on with garbage".
    ///
    /// KNOWN GAP, deliberately not closed here: the ordering check below is
    /// `x <= previous`, which evaluates to `false` for NaN, so a NaN x
    /// would PASS this guard and produce NaN pixels. It is unreachable in
    /// practice — every caller builds these points from sliders that are
    /// already clamped — so adding a guard to a stage whose byte-exactness
    /// against ~70 shipped assertions is load-bearing would be a change
    /// with risk and no reachable benefit. `MonotoneToneCurve`, whose
    /// points come from a user-editable (and hand-authorable) array, DOES
    /// check finiteness; see its `init?`. If a future change ever feeds
    /// unclamped values in here, close this first.
    init?(points: [CGPoint]) {
        guard points.count >= 3 else { return nil }
        for i in 1..<points.count where points[i].x <= points[i - 1].x { return nil }

        self.points = points
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        self.xs = xs
        self.ys = ys
        let m = Self.naturalSecondDerivatives(xs: xs, ys: ys)
        self.secondDerivatives = m

        let n = xs.count
        self.endSlope = Self.segmentSlope(
            at: xs[n - 1],
            x0: xs[n - 2], x1: xs[n - 1], y0: ys[n - 2], y1: ys[n - 1], m0: m[n - 2], m1: m[n - 1]
        )
    }

    /// Solves the standard natural-cubic tridiagonal system for the second
    /// derivatives, via the Thomas algorithm over the interior points.
    /// Spacing is NOT assumed uniform — Black Point moves `point0.x` away
    /// from 0, which makes the first interval shorter than the rest.
    private static func naturalSecondDerivatives(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        var m = [Double](repeating: 0, count: n)
        guard n > 2 else { return m }

        var lower = [Double](repeating: 0, count: n)
        var diagonal = lower
        var upper = lower
        var rhs = lower
        for i in 1..<(n - 1) {
            lower[i] = (xs[i] - xs[i - 1]) / 6
            diagonal[i] = (xs[i + 1] - xs[i - 1]) / 3
            upper[i] = (xs[i + 1] - xs[i]) / 6
            rhs[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
                - (ys[i] - ys[i - 1]) / (xs[i] - xs[i - 1])
        }

        var sweepUpper = [Double](repeating: 0, count: n)
        var sweepRHS = sweepUpper
        sweepUpper[1] = upper[1] / diagonal[1]
        sweepRHS[1] = rhs[1] / diagonal[1]
        for i in 2..<(n - 1) {
            let denominator = diagonal[i] - lower[i] * sweepUpper[i - 1]
            sweepUpper[i] = upper[i] / denominator
            sweepRHS[i] = (rhs[i] - lower[i] * sweepRHS[i - 1]) / denominator
        }

        m[n - 2] = sweepRHS[n - 2]
        var i = n - 3
        while i >= 1 {
            m[i] = sweepRHS[i] - sweepUpper[i] * m[i + 1]
            i -= 1
        }
        return m
    }

    private static func segmentValue(
        at u: Double, x0: Double, x1: Double, y0: Double, y1: Double, m0: Double, m1: Double
    ) -> Double {
        let h = x1 - x0
        let a = (x1 - u) / h
        let b = (u - x0) / h
        return a * y0 + b * y1 + ((a * a * a - a) * m0 + (b * b * b - b) * m1) * (h * h) / 6
    }

    private static func segmentSlope(
        at u: Double, x0: Double, x1: Double, y0: Double, y1: Double, m0: Double, m1: Double
    ) -> Double {
        let h = x1 - x0
        let a = (x1 - u) / h
        let b = (u - x0) / h
        return (y1 - y0) / h + ((-3 * a * a + 1) * m0 + (3 * b * b - 1) * m1) * h / 6
    }

    // MARK: - sRGB transfer function
    //
    // The IEC 61966-2-1 curve, extended ODD-SYMMETRICALLY to negative inputs
    // (`pow` of a negative base is undefined, so the sign is taken out and
    // put back). Negatives only arise transiently from upstream stages; they
    // land below `x0` and are clamped by the spline anyway, so the symmetry
    // choice is about being well-defined, not about matching a measurement.

    static func srgbEncode(_ x: Double) -> Double {
        let a = abs(x)
        let encoded = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1 / 2.4) - 0.055
        return x < 0 ? -encoded : encoded
    }

    static func srgbDecode(_ x: Double) -> Double {
        let a = abs(x)
        let decoded = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return x < 0 ? -decoded : decoded
    }

    /// The spline evaluated in its OWN (already sRGB-encoded) domain, with
    /// no encode/decode wrapper — clamped below `x0`, linearly extrapolated
    /// above the last point. `value(at:)` is exactly this sandwiched
    /// between encode and decode.
    ///
    /// Split out so a caller that already holds an encoded-domain value
    /// (a curve editor plotting control points, or a test comparing two
    /// interpolants on the same points) does not have to round-trip
    /// through the transfer function to reach the curve itself. Pure
    /// extraction — `value(at:)`'s behaviour is unchanged, and the existing
    /// assertions covering it are the proof.
    func splineValue(atEncoded u: Double) -> Double {
        let m = secondDerivatives
        let n = xs.count

        if u <= xs[0] { return ys[0] }
        if u >= xs[n - 1] { return ys[n - 1] + endSlope * (u - xs[n - 1]) }
        var i = 0
        while i < n - 2 && u > xs[i + 1] { i += 1 }
        return Self.segmentValue(at: u, x0: xs[i], x1: xs[i + 1], y0: ys[i], y1: ys[i + 1], m0: m[i], m1: m[i + 1])
    }

    /// The complete transfer function, matching the kernel exactly:
    /// encode -> spline (clamped below `x0`, linearly extrapolated above
    /// `x4`) -> decode. Kept in Swift so the maths can be unit-tested
    /// without a `CIContext`; the kernel is the twin that must agree.
    func value(at v: Double) -> Double {
        Self.srgbDecode(splineValue(atEncoded: Self.srgbEncode(v)))
    }

    // MARK: - Monotonicity (D64)

    /// How far the curve ever falls back below the highest value it has already reached, over `[x0, x4]` (0 for a curve that never goes down).
    /// Sampled (64 points per segment — the curve is a smooth cubic, so the sampling error is far below `reversalTolerance`).
    var deepestReversal: Double {
        var peak = -Double.infinity
        var deepest = 0.0
        let n = points.count
        for i in 0..<(n - 1) {
            let x0 = Double(points[i].x), x1 = Double(points[i + 1].x)
            for k in 0...64 {
                let y = splineValue(atEncoded: x0 + (x1 - x0) * Double(k) / 64)
                peak = max(peak, y)
                deepest = max(deepest, peak - y)
            }
        }
        return deepest
    }

    /// Reversals shallower than this are ignored (0.015, about 4 steps of 8-bit near black). It is set just above the deepest dip any SINGLE slider
    /// produces — Black Point -1 alone, 0.0104 — because single-slider curves are pinned against measurements of Apple's `CIToneCurve`
    /// (`testBlackPointNegativeCrushesShadows` and friends; the recorded "soft black" 0.03381) and must stay exactly as they are. Every
    /// combination with all sliders within +/-0.5 is also far below it (deepest 0.0007). The deeper reversals that remain are only reachable with
    /// two or more sliders near their limits.
    static let reversalTolerance = 0.015

    /// True when the curve does not go visibly DOWN as the input rises: no reversal deeper than `reversalTolerance` inside `[x0, x4]`, and a
    /// non-negative `endSlope` (above `x4` the curve continues along that slope, so a negative one darkens the headroom — the D64 symptom).
    var isEffectivelyMonotone: Bool {
        endSlope >= 0 && deepestReversal <= Self.reversalTolerance
    }

    /// `build(s)` makes the control points with every slider displacement scaled by `s` (1 = as the user set it, 0 = the identity line). Returns
    /// `build(1)` untouched whenever that curve is already effectively monotone — so every ordinary edit renders exactly as it always did — and otherwise the
    /// largest scale (found by a downward scan, then bisection) whose curve is monotone: an extreme COMBINATION of sliders (Shadows + Highlights, or
    /// Highlights + Black Point) is eased back just far enough that the brightest tones are never rendered darker than slightly less bright ones.
    /// `build(0)` is the identity, which is monotone, so a monotone scale always exists.
    static func monotonePoints(build: (Double) -> [CGPoint]) -> [CGPoint] {
        func isMonotone(_ s: Double) -> Bool { ToneCurveSpline(points: build(s))?.isEffectivelyMonotone ?? true }
        if isMonotone(1) { return build(1) }
        var high = 1.0
        var low = 0.0
        var s = 1.0 - 1.0 / 64
        while s > 0 {
            if isMonotone(s) { low = s; break }
            high = s
            s -= 1.0 / 64
        }
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if isMonotone(mid) { low = mid } else { high = mid }
        }
        return build(low)
    }
}
