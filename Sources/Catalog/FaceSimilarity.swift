import Foundation

/// How strictly "Select Similar" matches. A match only TICKS a face for the user to review (never assigns), so these are looser than the
/// 0.45 automatic-grouping threshold's zero-false-merge rule; the values are by-eye defaults, not measured. Small faces' prints are
/// unmeasured at their size.
enum FaceSimilarityStrength: String, CaseIterable, Identifiable, Sendable {
    case strict, normal, loose
    var id: String { rawValue }
    var limit: Float {
        switch self {
        case .strict: return 0.35
        case .normal: return 0.45   // the automatic-grouping threshold
        case .loose: return 0.60
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
