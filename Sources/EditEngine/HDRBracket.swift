import Foundation

/// Pure planning for an HDR bracket: which frame is the reference and what exposure gain every frame has relative to it.
///
/// A frame's relative brightness is `exposureTime * ISO / fNumber^2` (what the sensor collected, scaled by gain; the EXIF exposure BIAS is
/// deliberately ignored — it is what the camera asked for, not what it did). The REFERENCE is the median-brightness frame (the lower median
/// for an even count): it keeps the merge's geometry and tonal anchor in the middle of the bracket, so every other frame's gain stays small.
/// `gains[i] = brightness_i / brightness_reference`, the exposure ratio `HDRMergeFilter` divides by.
enum HDRBracket {
    struct ExposureMetadata: Equatable {
        var exposureTime: Double?
        var fNumber: Double?
        var iso: Double?

        /// Relative brightness, or nil if any of the three values is missing or not positive and finite.
        var brightness: Double? {
            guard let t = exposureTime, let f = fNumber, let iso, t > 0, f > 0, iso > 0, t.isFinite, f.isFinite, iso.isFinite else { return nil }
            return t * iso / (f * f)
        }
    }

    struct Plan: Equatable {
        let referenceIndex: Int
        /// Same order as the input frames; the reference's own entry is exactly 1.
        let gains: [Float]
    }

    enum PlanError: Error, Equatable {
        case tooFewFrames
        case tooManyFrames(limit: Int)
        case missingExposureData(frameIndex: Int)
        /// A frame is more than the allowed number of stops away from the reference.
        case gainOutOfRange(frameIndex: Int)
        /// Every frame has (nearly) the same exposure: not an exposure bracket.
        case noExposureDifference
    }

    /// Smallest spread, in stops, that counts as an exposure bracket (a few percent of metadata noise is not one).
    static let minimumSpreadInStops = 0.3

    static func plan(_ frames: [ExposureMetadata], maxFrames: Int, gainRange: ClosedRange<Float>) -> Result<Plan, PlanError> {
        guard frames.count >= 2 else { return .failure(.tooFewFrames) }
        guard frames.count <= maxFrames else { return .failure(.tooManyFrames(limit: maxFrames)) }
        var brightness: [Double] = []
        for (i, f) in frames.enumerated() {
            guard let b = f.brightness else { return .failure(.missingExposureData(frameIndex: i)) }
            brightness.append(b)
        }
        let order = brightness.indices.sorted { (brightness[$0], $0) < (brightness[$1], $1) } // ties broken by input order, by construction
        let reference = order[(order.count - 1) / 2]
        let spread = log2(brightness[order.last ?? reference] / brightness[order.first ?? reference])
        guard spread >= minimumSpreadInStops else { return .failure(.noExposureDifference) }
        var gains: [Float] = []
        for (i, b) in brightness.enumerated() {
            let g = i == reference ? 1 : Float(b / brightness[reference])
            guard gainRange.contains(g) else { return .failure(.gainOutOfRange(frameIndex: i)) }
            gains.append(g)
        }
        return .success(Plan(referenceIndex: reference, gains: gains))
    }
}
