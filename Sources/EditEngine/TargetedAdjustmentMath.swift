import CoreGraphics
import Foundation

/// Which Selective Color property a Targeted drag changes.
enum SelectiveColorProperty: String, CaseIterable, Equatable {
    case hue, saturation, luminance

    var label: String {
        switch self {
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .luminance: return "Luminance"
        }
    }
}

/// The control a Targeted adjustment drag changes.
enum TargetedTool: Equatable {
    /// The composite (RGB) point curve.
    case curve
    case selectiveColor(SelectiveColorProperty)
    /// The B&W Mix (only meaningful while Black & White is on).
    case grayMix

    /// The pipeline stage whose INPUT the sample is taken at.
    var sampleTruncation: EditPipeline.ColorSampleTruncation {
        switch self {
        case .curve: return .beforePointCurve
        case .selectiveColor: return .beforeSelectiveColor
        case .grayMix: return .beforeGrayMix
        }
    }

    /// The History row a finished drag leaves.
    var historySummary: String {
        switch self {
        case .curve: return "Targeted Curve"
        case .selectiveColor(let property): return "Targeted \(property.label)"
        case .grayMix: return "Targeted B&W Mix"
        }
    }
}

/// Pure math for the Targeted adjustment tool (drag up/down on the photo, the control under the pixel changes).
enum TargetedAdjustmentMath {
    /// How near (in curve x) an existing composite point must be to be MOVED rather than a new point added.
    static let curveSnapDistance: Double = 0.04

    /// The drag sensitivity: dragging the full pane height moves the value by this much (curve y, or a slider's -1...1 range).
    static let sensitivity: Double = 1.0

    /// A pixel whose strongest band weight is below this is treated as neutral and starts no colour drag: the per-band delta is
    /// normalised by the peak weight, so a near-neutral pixel would otherwise drive a band at the full rate from almost no
    /// colour. A by-eye cutoff (the kernels themselves only pass through below 0.0001), not a measured value.
    static let minimumPeakWeight: Double = 0.05

    /// Converts a drag into the signed value delta: `dy` is the drag's UPWARD distance in screen points, `paneHeight` the height of
    /// the image pane. Dragging up is positive.
    static func delta(upwardDrag dy: Double, paneHeight: Double) -> Double {
        guard paneHeight > 0, dy.isFinite, paneHeight.isFinite else { return 0 }
        return dy / paneHeight * sensitivity
    }

    // MARK: - Curve

    /// The point-curve x a sampled pixel sits at: Rec.709 luma of the PERCEPTUAL sample, encoded once more (the point-curve
    /// kernel evaluates on the doubly-encoded value, see `ToneCurvePoint`). Luma of three channels is an approximation of what the
    /// composite curve does per channel.
    static func curveX(forPerceptualRGB r: Double, _ g: Double, _ b: Double) -> Double {
        guard r.isFinite, g.isFinite, b.isFinite else { return 0 }
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return PerceptualEncoding.srgbEncode(min(max(luma, 0), 1))
    }

    /// The unit plot rect `ToneCurveEditing` works against (y flipped by that type).
    fileprivate static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// One composite-curve drag: the point it moves is chosen ONCE, at drag start, then `points(forDelta:)` is a pure function of
    /// the delta so replaying a drag is deterministic.
    struct CurveDrag: Equatable {
        /// The curve as it was when the drag began.
        let startPoints: [ToneCurvePoint]
        /// The curve with the dragged point already in place (the start curve, seeded with its endpoints when empty, plus an
        /// added point at the sample when one was added) and the index of the dragged point in it.
        let basePoints: [ToneCurvePoint]
        let index: Int
        let startY: Double

        /// Chooses the point for sample position `x` (0...1): an existing composite point within `curveSnapDistance` is moved
        /// (the nearest one); otherwise a point is added AT the curve's current value at `x` (so nothing jumps); at the 8-point
        /// cap, or where no validly separated point fits, the nearest existing point moves instead. Nil only if the existing
        /// curve is itself unusable or `x` is not finite.
        init?(points: [ToneCurvePoint], x: Double) {
            let seeded = points.isEmpty ? [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)] : points
            guard x.isFinite, let curve = MonotoneToneCurve(points: seeded) else { return nil }
            let x = min(max(x, 0), 1)

            let nearest = seeded.indices.min { abs(seeded[$0].x - x) < abs(seeded[$1].x - x) } ?? 0
            if abs(seeded[nearest].x - x) <= TargetedAdjustmentMath.curveSnapDistance {
                self.init(start: points, base: seeded, index: nearest)
                return
            }
            let y = min(max(curve.curveValue(atEncoded: x), 0), 1)
            let location = ToneCurveEditing.screenPoint(ToneCurvePoint(x: x, y: y), in: TargetedAdjustmentMath.unitRect)
            let added = ToneCurveEditing.adding(location, to: seeded, plotRect: TargetedAdjustmentMath.unitRect)
            if let inserted = added.insertedIndex {
                self.init(start: points, base: added.points, index: inserted)
            } else {
                // At the cap (or no room): the nearest point moves.
                self.init(start: points, base: seeded, index: nearest)
            }
        }

        private init(start: [ToneCurvePoint], base: [ToneCurvePoint], index: Int) {
            self.startPoints = start
            self.basePoints = base
            self.index = index
            self.startY = base[index].y
        }

        /// The curve for an upward drag of `delta` (curve-y units). Zero delta returns the curve exactly as it was before the
        /// drag. The result is validated: a curve `MonotoneToneCurve` would refuse falls back to the start curve, and a result
        /// that is exactly the identity line collapses to `[]` like `ToneCurveEditing.removing`.
        func points(forDelta delta: Double) -> [ToneCurvePoint] {
            guard delta.isFinite, delta != 0 else { return startPoints }
            // Monotone: the point may not cross its neighbours' heights (an endpoint: the other end of the curve), so a drag can
            // never invert the tone curve. A start curve that is itself non-monotone at this point is left unclamped.
            let lower = index > 0 ? basePoints[index - 1].y : 0
            let upper = index < basePoints.count - 1 ? basePoints[index + 1].y : 1
            var y = startY + delta
            if lower <= upper { y = min(max(y, lower), upper) }
            let target = ToneCurvePoint(x: basePoints[index].x, y: y)
            let rect = TargetedAdjustmentMath.unitRect
            let location = ToneCurveEditing.screenPoint(target, in: rect)
            let moved = ToneCurveEditing.moving(pointAt: index, to: location, in: basePoints, plotRect: rect)
            guard MonotoneToneCurve(points: moved) != nil else { return startPoints }
            if moved == [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)] { return [] }
            return moved
        }
    }

    // MARK: - Colour bands

    /// The 8 per-band deltas for a drag of `delta` over a pixel with these band `weights`: `delta * w_i / max(w)`, so the band
    /// the pixel sits in most changes by the full delta and its neighbours proportionally less. Nil when the pixel belongs to no
    /// band (a neutral pixel), so the caller leaves the edit alone.
    static func bandDeltas(weights: [Double], delta: Double) -> [Double]? {
        guard let peak = weights.max(), peak >= minimumPeakWeight, delta.isFinite else { return nil }
        return weights.map { max($0, 0) * delta / peak }
    }

    /// Each band's value after a drag: its drag-start value plus its delta, clamped to -1...1.
    static func bandValues(start: [Double], deltas: [Double]) -> [Double] {
        zip(start, deltas).map { min(max($0 + $1, -1), 1) }
    }

    /// `start` with each band's field moved by its delta, clamped to -1...1.
    static func applyingBandDeltas(
        _ deltas: [Double], keyPaths: [WritableKeyPath<EditState, Double>], to start: EditState
    ) -> EditState {
        var state = start
        let values = bandValues(start: keyPaths.map { start[keyPath: $0] }, deltas: deltas)
        for (keyPath, value) in zip(keyPaths, values) { state[keyPath: keyPath] = value }
        return state
    }
}
