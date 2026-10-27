import Foundation

/// Converts a detected horizon tilt into `EditState.straightenAngle`'s convention. Pure: no Vision or
/// Core Image, so the sign and rounding rules are unit-testable on their own. The sign is NOT assumed:
/// `StraightenSolverTests` / `HorizonDetectorTests` pin it against a real render through `EditPipeline`.
enum StraightenSolver {
    enum Outcome: Equatable {
        /// The Straighten angle to set, in degrees (positive = counter-clockwise), rounded to 0.1 and within ±45.
        case angle(Double)
        /// The horizon is within `levelThresholdDegrees` of level; nothing to do.
        case alreadyLevel
        /// Vision found no horizon (or reported a non-finite angle).
        case noHorizon
    }

    /// Below this magnitude (degrees) the photo counts as level. Under the 0.1 rounding step's own half-step
    /// plus a margin, so a 0.1° correction is not offered as a change nobody can see.
    static let levelThresholdDegrees = 0.15
    /// Matches the Straighten slider's range.
    static let maxDegrees = 45.0

    /// - Parameter visionHorizonAngle: `VNHorizonObservation.angle`, radians, or nil when no horizon was found.
    /// The result is the angle that LEVELS the photo. Measured (HorizonDetectorTests): a level landscape rotated
    /// by `straightenAngle = X` makes Vision report an angle of about `-X` (in radians), and the correction that
    /// levels it is `-X` degrees, so Vision's angle is used with its sign UNCHANGED (radians to degrees only).
    static func solve(visionHorizonAngle: Double?) -> Outcome {
        guard let radians = visionHorizonAngle, radians.isFinite else { return .noHorizon }
        let degrees = radians * 180 / .pi
        guard abs(degrees) >= levelThresholdDegrees else { return .alreadyLevel }
        let rounded = (degrees * 10).rounded() / 10
        let clamped = min(max(rounded, -maxDegrees), maxDegrees)
        return .angle(clamped == 0 ? 0 : clamped) // never -0.0
    }
}

/// User-facing wording for Auto Straighten outcomes that change nothing.
enum StraightenMessages {
    static let noHorizon = "No clear horizon was found in this photo. Use the Straighten slider instead."
    static let alreadyLevel = "The horizon already looks level."
    static let alreadyApplied = "Straighten is already set to the detected horizon angle."
    static let rotatedMeanwhile = "The photo was rotated while it was being analysed, so nothing was changed. Try again."
}
