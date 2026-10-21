import Foundation

/// Which Upright correction was asked for.
enum UprightMode: Equatable {
    /// Rotate so the dominant near-horizontal (or near-vertical) lines are level.
    case level
    /// Rotate and correct vertical keystone so the near-vertical lines become parallel.
    case vertical

    /// The History label.
    var historyLabel: String {
        switch self {
        case .level: return "Upright Level"
        case .vertical: return "Upright Vertical"
        }
    }
}

/// Turns detected line families into `EditState.straightenAngle` / `verticalPerspective` values. Pure. The formulas
/// are DERIVED from `EditPipeline.applyStraighten` / `applyPerspective` and pinned by round trips through the real
/// pipeline (`UprightRoundTripTests`), not assumed.
///
/// Vertical keystone: with `k` = (gap between two converging lines at the top row) / (gap at the bottom row) in the
/// frame the perspective stage sees, positive `verticalPerspective` scales the top row's width by `1 - v/2` (a corner
/// moves in by `v * 0.25 * width`), so `v = -2 (1 - k)` for `k < 1` (narrow the bottom) and `v = 2 (1 - 1/k)` for
/// `k > 1` (narrow the top). `k` is limited to [0.5, 2], which is exactly `v` in [-1, 1].
enum UprightSolver {
    struct Correction: Equatable {
        /// Degrees, positive = counter-clockwise (the Straighten slider's convention), rounded to 0.1.
        let straightenAngle: Double
        /// -1...1 (the Vertical slider), rounded to 0.01. Nil for Level, which leaves perspective alone.
        let verticalPerspective: Double?
    }

    enum Outcome: Equatable {
        case solved(Correction)
        /// What was measured is already upright: the sliders it controls should be 0.
        case alreadyUpright
        /// Not enough usable lines, or none that agree.
        case noLines
        /// Lines were found but cannot be measured: bunched too close together, or crossing inside the frame.
        case unmeasurable
    }

    /// Below this many degrees a rotation is not worth offering.
    static let levelThresholdDegrees = 0.15
    /// Below this a vertical correction is not worth offering (2% on the slider).
    static let verticalThreshold = 0.02
    /// Level needs at least this many lines in the family it uses, and the consensus below.
    static let minConsensusLines = 2
    /// At least half the family's length must lie within this many degrees of the weighted median tilt.
    static let consensusToleranceDegrees = 1.0
    /// Level refuses a correction beyond this: a tilt that large is a hillside or a road, not a tilted camera.
    static let maxLevelDegrees = 12.0
    /// A line agrees with a vanishing-point model when its slope (dx/dy) is within this of the model's (about 0.7 degrees).
    static let inlierTolerance = 0.012
    /// Vertical needs at least this many lines.
    static let minVerticalLines = 2
    /// The lines' centre-row positions must spread over at least this fraction of the width, or the convergence is
    /// not measurable.
    static let minSpreadFraction = 0.1

    static func solve(_ lines: UprightLineDetector.Lines, mode: UprightMode) -> Outcome {
        switch mode {
        case .level: return solveLevel(lines)
        case .vertical: return solveVertical(lines)
        }
    }

    // MARK: - Level

    /// A family that agrees with itself: at least `minConsensusLines` lines, and at least half of the length within
    /// `consensusToleranceDegrees` of the weighted median tilt. Returns that median.
    private static func consensusTilt(_ family: [UprightLineDetector.Line]) -> Double? {
        guard family.count >= minConsensusLines else { return nil }
        let samples = family.map { (value: $0.ccwTiltDegrees, weight: $0.span) }
        let median = weightedMedian(samples)
        let total = samples.reduce(0) { $0 + $1.weight }
        let agreeing = samples.filter { abs($0.value - median) <= consensusToleranceDegrees }.reduce(0) { $0 + $1.weight }
        guard median.isFinite, total > 0, agreeing >= 0.5 * total else { return nil }
        return median
    }

    /// Level prefers the near-horizontal family; the near-vertical one is used only when the horizontals do not agree,
    /// and then only if its lines are parallel (consensus), so converging building edges never level the photo. A
    /// tilt beyond `maxLevelDegrees` is not believed: a hillside or a road is not a horizon.
    private static func solveLevel(_ lines: UprightLineDetector.Lines) -> Outcome {
        guard let tilt = consensusTilt(lines.horizontal) ?? consensusTilt(lines.vertical),
              abs(tilt) <= maxLevelDegrees else { return .noLines }
        let angle = -tilt // the correction undoes the lines' counter-clockwise tilt
        guard abs(angle) >= levelThresholdDegrees else { return .alreadyUpright }
        return .solved(Correction(straightenAngle: roundedAngle(angle), verticalPerspective: nil))
    }

    // MARK: - Vertical

    private typealias Sample = (a: Double, b: Double, w: Double)

    /// Weighted least squares b = c0 + c1 * a.
    private static func fit(_ samples: [Sample]) -> (c0: Double, c1: Double)? {
        let totalWeight = samples.reduce(0) { $0 + $1.w }
        guard totalWeight > 0 else { return nil }
        let meanA = samples.reduce(0) { $0 + $1.w * $1.a } / totalWeight
        let meanB = samples.reduce(0) { $0 + $1.w * $1.b } / totalWeight
        let saa = samples.reduce(0) { $0 + $1.w * ($1.a - meanA) * ($1.a - meanA) }
        let sab = samples.reduce(0) { $0 + $1.w * ($1.a - meanA) * ($1.b - meanB) }
        guard saa > 0 else { return nil }
        let c1 = sab / saa
        return (meanB - c1 * meanA, c1)
    }

    private static func solveVertical(_ lines: UprightLineDetector.Lines) -> Outcome {
        let family = lines.vertical
        guard family.count >= minVerticalLines else { return .noLines }
        let width = Double(lines.width), height = Double(lines.height)

        // Each line as x = a + b * y_up about the image centre: `a` its x at the centre row, `b` = tan(theta).
        let samples = family.map { line -> Sample in (line.rho / cos(line.theta), tan(line.theta), line.span) }
        guard samples.allSatisfy({ $0.a.isFinite && $0.b.isFinite && $0.w > 0 }) else { return .noLines }
        let minSpread = minSpreadFraction * width

        // One outlier (a leaning lamp post, a roofline) must not move the fit: every pair of well-separated lines
        // proposes a vanishing-point model, the one that the most line length agrees with wins, and only its inliers
        // are fitted. Ties go to the first pair (deterministic).
        var best: (weight: Double, inliers: [Sample])?
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count where abs(samples[i].a - samples[j].a) >= minSpread {
                guard let model = fit([samples[i], samples[j]]) else { continue }
                let inliers = samples.filter { abs($0.b - (model.c0 + model.c1 * $0.a)) <= inlierTolerance }
                let weight = inliers.reduce(0) { $0 + $1.w }
                if weight > (best?.weight ?? 0) { best = (weight, inliers) }
            }
        }
        guard let chosen = best?.inliers, chosen.count >= minVerticalLines, let model = fit(chosen) else { return .unmeasurable }
        let positions = chosen.map(\.a)
        guard (positions.max() ?? 0) - (positions.min() ?? 0) >= minSpread else { return .unmeasurable }
        let c1 = model.c1, c0 = model.c0

        // 1. The rotation that puts the vanishing point straight above (or below) the centre: the tilt of the line
        //    through the centre. Positive = counter-clockwise, as Straighten.
        let rotation = atan(c0)
        // 2. Keystone, measured in the frame Straighten leaves: its bounding box is taller by the rotation.
        let boundsHeight = width * abs(sin(rotation)) + height * abs(cos(rotation))
        let halfHeight = boundsHeight / 2
        let inverseDistance = -c1 * cos(rotation) // 1 / (signed distance of the vanishing point from the centre)
        let ratio = halfHeight * inverseDistance
        guard abs(ratio) < 1 else { return .unmeasurable } // the lines cross inside the frame: not a building shot
        let k = (1 - ratio) / (1 + ratio)
        let clampedK = min(max(k, 0.5), 2)
        let vertical = clampedK < 1 ? -2 * (1 - clampedK) : 2 * (1 - 1 / clampedK)

        let degrees = rotation * 180 / .pi
        let straighten = abs(degrees) < levelThresholdDegrees ? 0 : roundedAngle(degrees)
        let keystone = abs(vertical) < verticalThreshold ? 0 : (min(max(vertical, -1), 1) * 100).rounded() / 100
        guard straighten != 0 || keystone != 0 else { return .alreadyUpright }
        return .solved(Correction(straightenAngle: straighten, verticalPerspective: keystone))
    }

    // MARK: - Helpers

    private static func roundedAngle(_ degrees: Double) -> Double {
        let rounded = (min(max(degrees, -45), 45) * 10).rounded() / 10
        return rounded == 0 ? 0 : rounded // never -0.0
    }

    /// The value at which the cumulative weight first reaches half (lower median for ties).
    static func weightedMedian(_ samples: [(value: Double, weight: Double)]) -> Double {
        let sorted = samples.sorted { $0.value < $1.value }
        let half = sorted.reduce(0) { $0 + $1.weight } / 2
        var running = 0.0
        for sample in sorted {
            running += sample.weight
            if running >= half { return sample.value }
        }
        return sorted.last?.value ?? 0
    }
}

/// User-facing wording for Upright outcomes that change nothing.
enum UprightMessages {
    static let noLines = "No clear straight lines were found in this photo. Use the Straighten and Vertical sliders instead."
    static let noLevelLines = "No clear horizontal lines were found in this photo. Use the Straighten slider instead."
    static let unmeasurable = "Lines were found, but they are too close together or cross inside the picture to measure a correction. Use the Vertical slider instead."
    static let alreadyUpright = "This photo already looks upright."
    static let alreadyApplied = "Upright is already applied."
}
