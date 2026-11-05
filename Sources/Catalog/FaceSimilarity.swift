import Foundation

/// How strictly "Select Similar" matches. A match only TICKS a face for the user to review (never assigns), so, unlike the 0.45
/// automatic-grouping threshold's zero-false-merge rule, Loose may tick other people (Strict and Normal sit below 0.45). Retuned 2026-11-05 from a probe on 149 small faces of 3 D610 group frames
/// (6 reference faces, identities judged by eye): the same person's 3 frames sat at 0.23-0.41, the first DIFFERENT person at 0.44
/// (then 0.50, 0.53, 0.56...). The old 0.60 ticked other people; 0.35/0.45 were by eye. Small sample, one scene, same-moment frames
/// (an easy case for "same person"), so treat the numbers as a first measurement, not a guarantee.
enum FaceSimilarityStrength: String, CaseIterable, Identifiable, Sendable {
    case strict, normal, loose
    var id: String { rawValue }
    var limit: Float {
        switch self {
        case .strict: return 0.33
        case .normal: return 0.42   // just under the first different person seen (0.44)
        case .loose: return 0.50    // inclusive limit: the different person measured at exactly 0.50 IS ticked; review before assigning
        }
    }
    var title: String {
        switch self {
        case .strict: return "Strict"
        case .normal: return "Normal"
        case .loose: return "Loose"
        }
    }
}

enum FaceSimilarity {
    struct Candidate: Sendable {
        var id: Int64
        var featurePrint: Data
    }

    struct Result: Equatable, Sendable {
        /// Candidate ids (in candidate order) whose nearest reference is within the limit.
        var matches: [Int64]
        /// Candidates skipped because they have no usable print (a legacy small face stored without one).
        var withoutPrint: Int
        /// References that had no usable print and were ignored.
        var referencesWithoutPrint: Int
    }

    /// A candidate is similar when its MINIMUM distance to any reference print is <= `limit` (inclusive). Unusable prints
    /// (`FeaturePrintVector.vector(from:)` is nil: empty, truncated, non-finite) are counted and skipped, never treated as distance 0.
    static func similar(references: [Data], candidates: [Candidate], limit: Float) -> Result {
        let vectors = references.compactMap(FeaturePrintVector.vector(from:))
        var result = Result(matches: [], withoutPrint: 0, referencesWithoutPrint: references.count - vectors.count)
        guard !vectors.isEmpty else {
            result.withoutPrint = candidates.filter { FeaturePrintVector.vector(from: $0.featurePrint) == nil }.count
            return result
        }
        for candidate in candidates {
            guard let vector = FeaturePrintVector.vector(from: candidate.featurePrint) else { result.withoutPrint += 1; continue }
            if vectors.contains(where: { FaceGrouping.distance($0, vector) <= limit }) { result.matches.append(candidate.id) }
        }
        return result
    }
}
