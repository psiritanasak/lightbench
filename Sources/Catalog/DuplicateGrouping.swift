import Foundation

/// Pure math + grouping for duplicate detection. No Vision, no I/O: feature prints arrive as cached float vectors, so
/// everything here is deterministic and unit-testable with injected numbers.
///
/// `VNFeaturePrintObservation.computeDistance` is the plain Euclidean distance between two unit-norm float vectors
/// (measured 2026-10-06: Vision 0.16525486 vs Euclidean 0.16525485975797702 on a real pair, and the same on two more;
/// `FeaturePrintMathTests` pins it against Vision on every run), which is what lets cached blobs be compared without Vision.
enum FeaturePrintVector {
    /// Revision 2 prints are 768 `Float`s.
    static let elementCount = 768

    /// The vector stored in `data`, or nil when it is not exactly `elementCount` finite floats (a truncated blob, a
    /// different revision's size, NaN/inf — all treated as "no usable print", never as a distance of 0).
    static func vector(from data: Data) -> [Float]? {
        guard data.count == elementCount * MemoryLayout<Float>.size else { return nil }
        // Copy bytes out (not `bindMemory`): a `Data` slice's base address is not guaranteed 4-byte aligned.
        let floats = [Float](unsafeUninitializedCapacity: elementCount) { buffer, count in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            count = elementCount
        }
        return floats.allSatisfy(\.isFinite) ? floats : nil
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "prints must have the same length")
        var sum: Float = 0
        for index in 0..<a.count {
            let delta = a[index] - b[index]
            sum += delta * delta
        }
        return sum.squareRoot()
    }
}

/// What the grouper needs to know about one photo.
struct DuplicateCandidate: Equatable, Sendable {
    var id: Int64
    var rating: Int
    var flag: FlagStatus
    var fileSize: Int64
    var importedAt: Date
    /// Present only for files that share a size with another photo (the scanner hashes lazily).
    var contentHash: String?
    var featurePrint: [Float]?
}

enum DuplicateKind: Int, Comparable, Sendable {
    /// Byte-identical files.
    case exact
    /// Re-encodes, resizes, exports of the same picture (feature-print distance <= `nearIdenticalDistance`).
    case nearIdentical
    /// Same scene, different frame (<= `similarShotsDistance`) — may be a burst the user wants to keep.
    case similarShots

    static func < (lhs: DuplicateKind, rhs: DuplicateKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DuplicateGroup: Equatable, Sendable, Identifiable {
    var kind: DuplicateKind
    /// Best first; `photoIDs[0]` is the one a "keep best" action keeps.
    var photoIDs: [Int64]
    /// The largest pairwise feature-print distance among the group's members (nil for an exact group).
    var maxDistance: Float?

    var id: Int64 { photoIDs[0] }
    var bestID: Int64 { photoIDs[0] }
    var othersIDs: [Int64] { Array(photoIDs.dropFirst()) }
}

enum DuplicateGrouping {
    /// Distances calibrated on real photos (docs/ROADMAP_HISTORY.md, "Duplicate detection spike"): resize 0.09, 5% crop
    /// 0.22, consecutive same-scene frames 0.165-0.42, unrelated >= 0.89.
    static let nearIdenticalDistance: Float = 0.12
    static let similarShotsDistance: Float = 0.35

    /// True when `a` should be kept over `b`: higher rating, then Picked over unflagged over Rejected, then the larger
    /// file, then the earlier import, then the lower id (a total order, so the result never depends on input order).
    static func isBetter(_ a: DuplicateCandidate, than b: DuplicateCandidate) -> Bool {
        if a.rating != b.rating { return a.rating > b.rating }
        if a.flag != b.flag { return a.flag.rawValue > b.flag.rawValue }
        if a.fileSize != b.fileSize { return a.fileSize > b.fileSize }
        if a.importedAt != b.importedAt { return a.importedAt < b.importedAt }
        return a.id < b.id
    }

    /// "Exact" means equal SHA-256 as of the cache row's size+mtime: a file rewritten with its modification time preserved
    /// (`rsync -t`, `touch -r`) keeps a stale cached hash until its size changes — an accepted trade-off of the cache.
    ///
    /// Groups of two or more photos, each photo in at most one group, ordered by kind then best id.
    ///
    /// 1. Exact: equal `contentHash`.
    /// 2. Near: one representative per exact group (its best member) plus every photo not in one, clustered by
    ///    feature-print distance with COMPLETE linkage (a photo joins a cluster only if it is within the limit of EVERY
    ///    member). Single linkage was rejected: real bursts chain (a median nearest neighbour of 0.33 on one trip), so
    ///    A~B, B~C would pull A..Z into one giant group. Representatives are visited in id order, so the result is
    ///    deterministic. A near group absorbs the full exact group of each representative in it.
    ///
    /// `includeSimilarShots == false` limits near clustering to `nearIdenticalDistance`.
    static func groups(
        from candidates: [DuplicateCandidate],
        includeSimilarShots: Bool,
        nearIdenticalDistance: Float = DuplicateGrouping.nearIdenticalDistance,
        similarShotsDistance: Float = DuplicateGrouping.similarShotsDistance
    ) -> [DuplicateGroup] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func ordered(_ ids: [Int64]) -> [Int64] {
            ids.compactMap { byID[$0] }.sorted { isBetter($0, than: $1) }.map(\.id)
        }

        // 1. Exact groups.
        var hashBuckets: [String: [Int64]] = [:]
        for candidate in byID.values {
            if let hash = candidate.contentHash { hashBuckets[hash, default: []].append(candidate.id) }
        }
        var exactMembers: [Int64: [Int64]] = [:] // best member id -> all members, best first
        var inExactGroup = Set<Int64>()
        for ids in hashBuckets.values where ids.count > 1 {
            let members = ordered(ids)
            exactMembers[members[0]] = members
            inExactGroup.formUnion(members)
        }

        // 2. Near clusters over representatives. TWO stages, so widening the limit can never break up a tight pair:
        //    first cluster at the near-identical limit, then (only when asked) merge those clusters AS WHOLE UNITS at the
        //    similar-shots limit. A one-pass greedy at the wide limit was rejected: with A, B (0.34 from A), C (0.02 from
        //    B, 0.36 from A) it put B with A and stranded C, losing the 0.02 near-copy the tight pass finds.
        let representatives = byID.values
            .filter { exactMembers[$0.id] != nil || !inExactGroup.contains($0.id) }
            .filter { $0.featurePrint != nil }
            .sorted { $0.id < $1.id }
        func clusterGreedily(_ units: [[DuplicateCandidate]], limit: Float) -> [[DuplicateCandidate]] {
            var clusters: [[DuplicateCandidate]] = []
            for unit in units {
                let home = clusters.firstIndex { cluster in
                    unit.allSatisfy { a in
                        cluster.allSatisfy { b in
                            guard let pa = a.featurePrint, let pb = b.featurePrint else { return false }
                            return FeaturePrintVector.distance(pa, pb) <= limit
                        }
                    }
                }
                if let home { clusters[home].append(contentsOf: unit) } else { clusters.append(unit) }
            }
            return clusters
        }
        var clusters = clusterGreedily(representatives.map { [$0] }, limit: nearIdenticalDistance)
        if includeSimilarShots {
            clusters = clusterGreedily(clusters.sorted { ($0.map(\.id).min() ?? 0) < ($1.map(\.id).min() ?? 0) }, limit: similarShotsDistance)
        }

        var result: [DuplicateGroup] = []
        var clusteredRepIDs = Set<Int64>()
        for cluster in clusters where cluster.count > 1 {
            var widest: Float = 0
            for i in 0..<cluster.count {
                for j in (i + 1)..<cluster.count {
                    if let a = cluster[i].featurePrint, let b = cluster[j].featurePrint {
                        widest = max(widest, FeaturePrintVector.distance(a, b))
                    }
                }
            }
            let members = cluster.flatMap { exactMembers[$0.id] ?? [$0.id] }
            result.append(DuplicateGroup(
                kind: widest <= nearIdenticalDistance ? .nearIdentical : .similarShots,
                photoIDs: ordered(members), maxDistance: widest
            ))
            clusteredRepIDs.formUnion(cluster.map(\.id))
        }
        // Exact groups whose representative did not join a near cluster stay exact groups.
        for (bestID, members) in exactMembers where !clusteredRepIDs.contains(bestID) {
            result.append(DuplicateGroup(kind: .exact, photoIDs: members, maxDistance: nil))
        }
        return result.sorted { ($0.kind, $0.bestID) < ($1.kind, $1.bestID) }
    }
}
