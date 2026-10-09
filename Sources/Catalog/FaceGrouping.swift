import Accelerate
import Foundation

/// Decides which faces belong to which person. Pure: feature prints arrive as stored blobs, so everything is deterministic and
/// unit-tested with injected vectors (the same split as `DuplicateGrouping`).
///
/// Conservative by design — the 2026-10-09 spike (docs/ROADMAP_HISTORY.md) found clean separation at PAIRWISE distance <= 0.47 and a
/// grey zone between about 0.5 and 0.7, on a small sample — so automatic decisions use a HIGH-PRECISION limit measured between FACES
/// (never against a centroid: a centroid sits inside its cluster, so centroid distances are systematically smaller and a person would
/// snowball run after run — measured by the reviewer: a person's diameter grew 0.52 -> 0.94 over 5 single-face runs):
///
/// 1. A person is ANCHORED when it has CONFIRMED faces (the user's own choices): an unconfirmed face fits it when its NEAREST confirmed
///    face is within `assign`. A person with no confirmed face fits a face only when the face is within `assign` of EVERY member —
///    complete linkage on admission — so an automatic person's diameter can never exceed `assign`, across runs.
/// 2. Each UNCONFIRMED face goes to the person it fits best. Hysteresis: a face already in a person stays while it still fits within
///    `assign + unassignMargin`, and moves only to a person that fits better by more than the margin.
/// 3. Two faces of the same PHOTO never join the same person (one body, one face: look-alikes and siblings in one frame).
///    (Policy, deliberately: an anchored person is judged by its NEAREST confirmed face, an automatic one by its FARTHEST member, so the
///    user's own choices attract more than the program's: a face prefers a person the user has confirmed.)
/// 4. Unassigned faces are clustered with COMPLETE linkage at `cluster` (and the same-photo rule); clusters of `minimumClusterSize`+
///    become new unnamed people, the rest stay "unsorted". A leftover cluster may sit near an existing person and still become a new
///    one (its members are each farther than `assign`): conservative, and the user can merge.
/// Confirmed faces are never in the plan at all.
enum FaceGrouping {
    struct Thresholds: Equatable, Sendable {
        /// Just under the spike's zero-false-merge point (0.47 at 40 % padding).
        var assign: Float = 0.45
        var cluster: Float = 0.45
        var unassignMargin: Float = 0.05
        var minimumClusterSize = 2
        /// Complete linkage is quadratic: at most this many leftover faces are clustered per run — the NEWEST ones (highest ids), so
        /// old singletons cannot starve new faces; the rest wait. It is a RECENCY WINDOW: in a very large library an old face and a newer
        /// face of the same rarely-seen person, more than this many leftovers apart, are never clustered (the user can still merge).
        var maximumLeftoverPerRun = 5000
    }

    struct Plan: Equatable, Sendable {
        /// Changes to existing faces: a person, or nil to take an unconfirmed face out of its person.
        var assignments: [FaceAssignment] = []
        /// Face ids that form NEW unnamed people (each inner array becomes one person).
        var newGroups: [[Int64]] = []
        /// Leftover faces not clustered this run because of `maximumLeftoverPerRun`.
        var deferred = 0

        var isEmpty: Bool { assignments.isEmpty && newGroups.isEmpty }
    }

    /// Euclidean distance between two prints (Accelerate: ~10x faster than a scalar loop; same value as `FeaturePrintVector.distance`).
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "prints must have the same length")
        var squared: Float = 0
        vDSP_distancesq(a, 1, b, 1, &squared, vDSP_Length(a.count))
        return squared.squareRoot()
    }

    private struct Member {
        var id: Int64
        var photoId: Int64
        var confirmed: Bool
        var vector: [Float]
    }

    static func plan(faces: [FaceGroupingInput], exclusions: [Int64: Set<Int64>], thresholds: Thresholds = Thresholds()) -> Plan {
        var vectors: [Int64: [Float]] = [:]
        for face in faces {
            if let vector = FeaturePrintVector.vector(from: face.featurePrint) { vectors[face.id] = vector }
        }
        let usable = faces.filter { vectors[$0.id] != nil }.sorted { $0.id < $1.id }

        // Current membership. Updated as this run decides, so later faces see earlier decisions (complete linkage and the same-photo
        // rule hold within the run too).
        var members: [Int64: [Member]] = [:]
        for face in usable {
            guard let person = face.personId, let vector = vectors[face.id] else { continue }
            members[person, default: []].append(Member(id: face.id, photoId: face.photoId, confirmed: face.isConfirmed, vector: vector))
        }
        // Cheap necessary condition for an AUTOMATIC person: a face within `assign` of every member is within `assign` of their mean
        // (convexity). Centroids are computed once per run; stale ones only ever cost a missed admission, never a wrong one.
        // For an ANCHORED person a bounding ball around its confirmed faces (exact by the triangle inequality): a face farther than
        // `radius + cap` from the ball's centre cannot be within `cap` of any confirmed face.
        var centroids: [Int64: [Float]] = [:]
        var anchored = Set<Int64>()
        var balls: [Int64: (center: [Float], radius: Float)] = [:]
        for (person, list) in members {
            centroids[person] = mean(list.map(\.vector))
            let confirmed = list.filter(\.confirmed)
            if !confirmed.isEmpty {
                anchored.insert(person)
                let center = mean(confirmed.map(\.vector))
                balls[person] = (center, confirmed.map { distance(center, $0.vector) }.max() ?? 0)
            }
        }
        let peopleInOrder = members.keys.sorted()

        /// How well `face` fits `person` (smaller is better), or nil when it does not fit within `cap` or may not link (same photo).
        /// A person with no OTHER member fits a face only when the face IS that person (fit 0); an emptied person is nil, never a magnet.
        func fit(_ vector: [Float], faceID: Int64, photoID: Int64, person: Int64, cap: Float) -> Float? {
            guard let list = members[person] else { return nil }
            var hasOthers = false
            for member in list where member.id != faceID {
                hasOthers = true
                if member.photoId == photoID { return nil }
            }
            if !hasOthers { return list.contains { $0.id == faceID } ? 0 : nil }
            if anchored.contains(person) {
                if let ball = balls[person], distance(vector, ball.center) - ball.radius > cap + 1e-4 { return nil }
                var nearest = Float.infinity
                for member in list where member.confirmed && member.id != faceID { nearest = min(nearest, distance(vector, member.vector)) }
                return nearest <= cap ? nearest : nil
            }
            if let centroid = centroids[person], distance(vector, centroid) > cap { return nil }
            var worst: Float = 0
            for member in list where member.id != faceID {
                let d = distance(vector, member.vector)
                if d > cap { return nil }
                worst = max(worst, d)
            }
            return worst
        }

        func remove(_ faceID: Int64, from person: Int64) {
            members[person]?.removeAll { $0.id == faceID }
        }

        var plan = Plan()
        var leftover: [Int64] = []
        for face in usable where !face.isConfirmed {
            guard let vector = vectors[face.id] else { continue }
            let excluded = exclusions[face.id] ?? []
            let current = face.personId
            // A face alone in its (automatic) person says nothing about whether it belongs there: it is weakly placed and moves to ANY
            // person it fits, otherwise it stays (never dissolved: a named automatic person would be left empty).
            let sole = current.map { (members[$0]?.count ?? 0) <= 1 } ?? false
            let currentFit = sole ? 0 : current.flatMap {
                fit(vector, faceID: face.id, photoID: face.photoId, person: $0, cap: thresholds.assign + thresholds.unassignMargin)
            }
            var best: (person: Int64, fit: Float)?
            for person in peopleInOrder where !excluded.contains(person) && !(sole && person == current) {
                guard let value = fit(vector, faceID: face.id, photoID: face.photoId, person: person, cap: thresholds.assign) else { continue }
                if let known = best { if value < known.fit { best = (person, value) } } else { best = (person, value) }
            }
            if let best {
                if best.person == current { continue }
                let moves: Bool
                if current == nil || sole { moves = true } else if let currentFit { moves = best.fit + thresholds.unassignMargin < currentFit } else { moves = true }
                if moves {
                    if let current { remove(face.id, from: current) }
                    members[best.person, default: []].append(Member(id: face.id, photoId: face.photoId, confirmed: false, vector: vector))
                    plan.assignments.append(FaceAssignment(faceID: face.id, personID: best.person))
                }
            } else if let current {
                if !sole && currentFit == nil {
                    remove(face.id, from: current)
                    plan.assignments.append(FaceAssignment(faceID: face.id, personID: nil))
                    leftover.append(face.id)
                }
            } else {
                leftover.append(face.id)
            }
        }

        // Complete-linkage clusters among the leftovers (newest first when capped).
        leftover.sort()
        let considered = Array(leftover.suffix(thresholds.maximumLeftoverPerRun))
        plan.deferred = leftover.count - considered.count
        let photoOf = Dictionary(usable.map { ($0.id, $0.photoId) }, uniquingKeysWith: { first, _ in first })
        var clusters: [[Int64]] = []
        for id in considered {
            guard let vector = vectors[id], let photo = photoOf[id] else { continue }
            let home = clusters.firstIndex { cluster in
                cluster.allSatisfy { member in
                    guard let other = vectors[member], photoOf[member] != photo else { return false }
                    return distance(vector, other) <= thresholds.cluster
                }
            }
            if let home { clusters[home].append(id) } else { clusters.append([id]) }
        }
        plan.newGroups = clusters.filter { $0.count >= thresholds.minimumClusterSize }
        return plan
    }

    private static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors { for index in 0..<sum.count { sum[index] += vector[index] } }
        return sum.map { $0 / Float(vectors.count) }
    }
}
