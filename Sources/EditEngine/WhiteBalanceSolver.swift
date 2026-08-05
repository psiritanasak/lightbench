import CoreImage
import CoreImage.CIFilterBuiltins

/// Finds the Temperature/Tint slider values that neutralize a sampled
/// pixel (make it R=G=B) — the math behind the WB eyedropper.
///
/// `CITemperatureAndTint` (which `EditPipeline.whiteBalanced` wraps) is a
/// full 3×3 chromatic-adaptation matrix, not a per-channel diagonal scale —
/// MEASURED: a 0.18 gray input's per-channel gains at temperature 9500 do
/// NOT predict the filter's actual output on a *different* input run
/// through the same transform (gray-derived gains predict r≈2.10 on
/// `(1.4,0.5,0.2)`, but the real measured output is `1.80724` — see
/// `EditPipeline`'s WB doc comment and `testWhiteBalancePreservesHighlight
/// Headroom`). There is no documented closed-form inverse. So instead of a
/// probe-measured constant baked in ahead of time (every other adjustment
/// in this app), this runs the SAME live-measurement discipline at
/// tap-time: try candidate (temperature, tint) pairs against the real
/// filter and converge on whichever one neutralizes the sample.
///
/// A genuine new-Core-Image-investigation feature, so every number below
/// was verified with a real compiled probe before shipping, exactly like
/// every prior feature's filter constants.
enum WhiteBalanceSolver {
    enum Outcome: Equatable {
        /// Converged to a genuinely neutral result (`bestError` at/below
        /// `kGoodEnoughError`).
        case solved(temperature: Double, tint: Double)
        /// The search's best candidate is the edge of `temperatureRange`/
        /// `tintRange` (or otherwise still has a real residual cast) —
        /// MEASURED: some strong casts (e.g. a saturated orange) are too
        /// strong for `CITemperatureAndTint` to fully correct within the
        /// UI's own -100...100/3500...9500 range; the search finds the
        /// best ACHIEVABLE point, not a fully neutral one. Still applied
        /// (better than nothing) but the caller should tell the user it
        /// wasn't a full fix, not present it as if it were.
        case solvedPartially(temperature: Double, tint: Double)
        /// The sample was too dark to carry reliable color-cast
        /// information — see `minSampleLuminance`.
        case rejectedTooDark
    }

    /// Mirrors `ContentView`'s Temperature slider range exactly — the
    /// "duplicate with a cross-reference comment" pattern already used
    /// elsewhere in this codebase (e.g. `CropOverlayView.maxInset` mirrors
    /// `EditPipeline.kMaxCropInset`), since the UI range lives as a literal
    /// in `ContentView.swift`, not a shared constant.
    static let temperatureRange = 3500.0...9500.0
    /// Mirrors `ContentView`'s Tint slider range.
    static let tintRange = -100.0...100.0

    /// Below this linear luminance, a real camera image's chromaticity
    /// ratio is dominated by sensor noise/8-bit quantization, not genuine
    /// color-cast information — REASONED, not directly measured by a
    /// synthetic float probe (which has no noise to reproduce the failure
    /// mode this guards against); the search itself is mathematically
    /// scale-invariant even below this floor (MEASURED: full- and
    /// half-brightness versions of the same cast converge to the identical
    /// result), so this threshold exists for real-world signal quality, not
    /// because the algorithm breaks down.
    static let minSampleLuminance = 0.02

    /// `bestError` at/below this is treated as a genuinely neutral result;
    /// above it, as `solvedPartially`. MEASURED calibration: well-converged
    /// samples (a mild cast, a cool cast, a green cast) landed at
    /// 0.00009–0.0009; boundary-clamped, NOT-actually-neutral samples (a
    /// strong orange cast, a strong magenta cast) landed at 0.004–0.052 —
    /// over 4x higher than the worst genuinely-good case, giving a
    /// comfortable, real separation margin for this cutoff.
    private static let kGoodEnoughError = 0.0015

    /// The error metric: sum of squared pairwise channel differences after
    /// applying the candidate transform, normalized by the transformed
    /// pixel's own brightness. MEASURED necessity for the normalization:
    /// without it, candidates that merely darken the pixel are spuriously
    /// favored (an un-normalized search gave a measurably different, worse
    /// result on a real test cast); with it, the search is scale-invariant
    /// (MEASURED: identical results at full- and half-brightness).
    private static func neutralityError(of pixel: (r: Double, g: Double, b: Double)) -> Double {
        let (r, g, b) = pixel
        let ssd = (r - g) * (r - g) + (g - b) * (g - b) + (b - r) * (b - r)
        let sum = r + g + b
        return sum.magnitude > 1e-6 ? ssd / (sum * sum) : ssd
    }

    /// Falls back to device RGB if the named space is ever unavailable —
    /// same defensive pattern as `HistogramComputer.displayColorSpace`, not
    /// a force-unwrap, since this is reachable from a live tap, not just
    /// static setup.
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf
    ])

    /// Builds the 1×1 sample image ONCE per `solve` call (not once per
    /// candidate) — `evaluate` only varies `temperature`/`tint` against a
    /// fixed input, so constructing it up front both avoids redundant work
    /// across the ~52 evaluations and keeps the fallible `CIColor` init off
    /// the hot loop, where a force-unwrap would otherwise be tempting.
    private static func evaluate(input: CIImage, temperature: Double, tint: Double) -> Double {
        let output = EditPipeline.whiteBalanced(input, temperature: temperature, tint: tint)

        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &buffer, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: linearSpace
        )
        return neutralityError(of: (Double(buffer[0]), Double(buffer[1]), Double(buffer[2])))
    }

    /// Coarse grid (7 temperature steps × 6 tint steps = 42 evaluations)
    /// followed by one local refine pass on each axis (5 + 5 = 10
    /// evaluations), 52 evaluations total. MEASURED: gives comparable
    /// accuracy to a much finer (179-evaluation) search on real test casts,
    /// at roughly half the cost (~13-30ms vs ~60ms on a real device,
    /// depending on Core Image's shader-cache warmth) — the finer search
    /// wasn't measurably more correct, just slower. MEASURED REJECTED
    /// alternative: batching all coarse-grid candidates into one wide
    /// composited image + a single render call, hoping to amortize
    /// per-render overhead — this was dramatically SLOWER (402ms vs ~15ms
    /// for the same 42 candidates via separate small renders), because
    /// Core Image's evaluation cost for a wide `composited(over:)` chain
    /// scales badly with layer count. Real per-call overhead (MEASURED:
    /// ~0.26ms per 1×1 render+readback, filter construction itself is
    /// negligible at ~0.01ms) is what actually dominates cost, not the
    /// number of separate filter objects.
    ///
    /// Call from a background context (`Task.detached`) — MEASURED: even
    /// this reduced search takes ~13-30ms on real hardware, which is a
    /// visible-hitch risk if run synchronously on the main thread from a
    /// tap handler. Mirrors `HistogramComputer`'s own "independent CIContext,
    /// safe off the main thread" precedent.
    static func solve(sampleLinearRGB sample: (r: Double, g: Double, b: Double)) -> Outcome {
        let luminance = (sample.r + sample.g + sample.b) / 3
        guard luminance >= minSampleLuminance else { return .rejectedTooDark }

        // `CIColor`'s initializer is failable; handled explicitly rather
        // than force-unwrapped, even though a well-formed 0...1-ish sample
        // is expected to always succeed — this is reachable from a live
        // tap, not just static setup, so CLAUDE.md's "no force-unwraps
        // outside tests" applies here same as everywhere else.
        guard let color = CIColor(red: sample.r, green: sample.g, blue: sample.b, alpha: 1, colorSpace: linearSpace) else {
            return .rejectedTooDark
        }
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

        var bestTemp = 6500.0
        var bestTint = 0.0
        var bestError = Double.greatestFiniteMagnitude

        let temps = Swift.stride(from: temperatureRange.lowerBound, through: temperatureRange.upperBound, by: 1000)
        let tints = Swift.stride(from: tintRange.lowerBound, through: tintRange.upperBound, by: 40)
        for temperature in temps {
            for tint in tints {
                let error = evaluate(input: input, temperature: temperature, tint: tint)
                if error < bestError { bestError = error; bestTemp = temperature; bestTint = tint }
            }
        }

        let temperatureLow = Swift.max(temperatureRange.lowerBound, bestTemp - 500)
        let temperatureHigh = Swift.min(temperatureRange.upperBound, bestTemp + 500)
        for temperature in Swift.stride(from: temperatureLow, through: temperatureHigh, by: (temperatureHigh - temperatureLow) / 4) {
            let error = evaluate(input: input, temperature: temperature, tint: bestTint)
            if error < bestError { bestError = error; bestTemp = temperature }
        }

        let tintLow = Swift.max(tintRange.lowerBound, bestTint - 20)
        let tintHigh = Swift.min(tintRange.upperBound, bestTint + 20)
        for tint in Swift.stride(from: tintLow, through: tintHigh, by: (tintHigh - tintLow) / 4) {
            let error = evaluate(input: input, temperature: bestTemp, tint: tint)
            if error < bestError { bestError = error; bestTint = tint }
        }

        return bestError <= kGoodEnoughError
            ? .solved(temperature: bestTemp, tint: bestTint)
            : .solvedPartially(temperature: bestTemp, tint: bestTint)
    }
}
