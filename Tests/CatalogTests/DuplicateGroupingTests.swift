import XCTest
@testable import PhotoApp

final class DuplicateGroupingTests: XCTestCase {
    /// A unit vector on the circle spanned by the first two axes: two vectors `a` radians apart are `2*sin(a/2)` apart.
    private func vec(angle: Float) -> [Float] {
        var v = [Float](repeating: 0, count: FeaturePrintVector.elementCount)
        v[0] = cos(angle); v[1] = sin(angle)
        return v
    }

    /// The angle that puts a point exactly `distance` from angle 0.
    private func angle(forDistance distance: Float) -> Float { 2 * asin(distance / 2) }

    private func candidate(
        _ id: Int64, rating: Int = 0, flag: FlagStatus = .none, size: Int64 = 1000, imported: Double = 0,
        hash: String? = nil, angle: Float? = nil
    ) -> DuplicateCandidate {
        DuplicateCandidate(id: id, rating: rating, flag: flag, fileSize: size, importedAt: Date(timeIntervalSince1970: imported),
                           contentHash: hash, featurePrint: angle.map(vec))
    }

    private func ids(_ groups: [DuplicateGroup]) -> [[Int64]] { groups.map(\.photoIDs) }

    // MARK: math

    func testVectorRejectsWrongLengthAndNonFiniteValues() {
        let good = vec(angle: 0)
        let data = good.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(FeaturePrintVector.vector(from: data), good)
        XCTAssertNil(FeaturePrintVector.vector(from: data.dropLast(4)), "truncated")
        XCTAssertNil(FeaturePrintVector.vector(from: Data()))
        var bad = good; bad[5] = .nan
        XCTAssertNil(FeaturePrintVector.vector(from: bad.withUnsafeBufferPointer { Data(buffer: $0) }), "NaN is not a usable print")
        bad[5] = .infinity
        XCTAssertNil(FeaturePrintVector.vector(from: bad.withUnsafeBufferPointer { Data(buffer: $0) }))
    }

    func testDistanceIsEuclideanSymmetricAndZeroForItself() {
        let a = vec(angle: 0), b = vec(angle: angle(forDistance: 0.3))
        XCTAssertEqual(FeaturePrintVector.distance(a, b), 0.3, accuracy: 1e-5)
        XCTAssertEqual(FeaturePrintVector.distance(a, b), FeaturePrintVector.distance(b, a))
        XCTAssertEqual(FeaturePrintVector.distance(a, a), 0)
    }

    // MARK: best pick

    func testBestPrefersRatingThenFlagThenSizeThenEarlierImportThenLowerID() {
        func best(_ list: [DuplicateCandidate]) -> Int64 { list.sorted { DuplicateGrouping.isBetter($0, than: $1) }[0].id }
        XCTAssertEqual(best([candidate(1, rating: 1, size: 9_999), candidate(2, rating: 3, size: 1)]), 2, "rating beats size")
        XCTAssertEqual(best([candidate(1, rating: 3, flag: .none), candidate(2, rating: 3, flag: .picked)]), 2, "picked beats unflagged")
        XCTAssertEqual(best([candidate(1, flag: .rejected), candidate(2, flag: .none)]), 2, "unflagged beats rejected")
        XCTAssertEqual(best([candidate(1, size: 10), candidate(2, size: 20)]), 2, "larger file")
        XCTAssertEqual(best([candidate(1, imported: 200), candidate(2, imported: 100)]), 2, "earlier import")
        XCTAssertEqual(best([candidate(7, imported: 100), candidate(3, imported: 100)]), 3, "lowest id is the final tie-break")
    }

    // MARK: exact

    func testExactGroupsByHashWithBestFirst() {
        let groups = DuplicateGrouping.groups(from: [
            candidate(1, hash: "A"), candidate(2, rating: 5, hash: "A"), candidate(3, hash: "B"), candidate(4, hash: nil),
        ], includeSimilarShots: false)
        XCTAssertEqual(ids(groups), [[2, 1]])
        XCTAssertEqual(groups[0].kind, .exact)
        XCTAssertNil(groups[0].maxDistance)
        XCTAssertEqual(groups[0].bestID, 2)
        XCTAssertEqual(groups[0].othersIDs, [1])
    }

    func testASinglePhotoOrEmptyInputMakesNoGroup() {
        XCTAssertTrue(DuplicateGrouping.groups(from: [], includeSimilarShots: true).isEmpty)
        XCTAssertTrue(DuplicateGrouping.groups(from: [candidate(1, hash: "A", angle: 0)], includeSimilarShots: true).isEmpty)
    }

    // MARK: near

    func testNearIdenticalGroupsWithinTheTightLimitAndSimilarShotsNeedTheOptIn() {
        let items = [candidate(1, angle: 0), candidate(2, angle: angle(forDistance: 0.09)), candidate(3, angle: angle(forDistance: 0.30))]
        let tight = DuplicateGrouping.groups(from: items, includeSimilarShots: false)
        XCTAssertEqual(ids(tight), [[1, 2]])
        XCTAssertEqual(tight[0].kind, .nearIdentical)
        let loose = DuplicateGrouping.groups(from: items, includeSimilarShots: true)
        XCTAssertEqual(loose.count, 1)
        XCTAssertEqual(Set(loose[0].photoIDs), [1, 2, 3])
        XCTAssertEqual(loose[0].kind, .similarShots, "a group is labelled by its WIDEST link")
        XCTAssertEqual(loose[0].maxDistance ?? 0, 0.30, accuracy: 1e-4)
    }

    /// The limit itself is INCLUSIVE: a pair whose computed distance equals the limit exactly groups; one ulp tighter does not.
    func testThresholdsAreInclusiveAtTheExactLimit() {
        var a = [Float](repeating: 0, count: FeaturePrintVector.elementCount)
        var b = a
        a[0] = 1; b[0] = 1; b[1] = 0.1
        let d = FeaturePrintVector.distance(a, b)
        let items = [
            DuplicateCandidate(id: 1, rating: 0, flag: .none, fileSize: 1, importedAt: Date(timeIntervalSince1970: 0), contentHash: nil, featurePrint: a),
            DuplicateCandidate(id: 2, rating: 0, flag: .none, fileSize: 1, importedAt: Date(timeIntervalSince1970: 0), contentHash: nil, featurePrint: b),
        ]
        XCTAssertEqual(DuplicateGrouping.groups(from: items, includeSimilarShots: false, nearIdenticalDistance: d).count, 1, "== limit groups")
        XCTAssertTrue(DuplicateGrouping.groups(from: items, includeSimilarShots: false, nearIdenticalDistance: d.nextDown).isEmpty, "one ulp under does not")
        XCTAssertEqual(DuplicateGrouping.groups(from: items, includeSimilarShots: true, nearIdenticalDistance: 0.01, similarShotsDistance: d).count, 1)
        XCTAssertTrue(DuplicateGrouping.groups(from: items, includeSimilarShots: true, nearIdenticalDistance: 0.01, similarShotsDistance: d.nextDown).isEmpty)
    }

    /// A (id 1) at 0, B 0.34 from A, C 0.02 from B and ~0.36 from A. The tight pair B~C must be found at BOTH settings: a
    /// one-pass wide greedy grouped B with A and stranded C.
    func testWideningTheLimitNeverBreaksUpATightPair() {
        let b = angle(forDistance: 0.34)
        let c = b + angle(forDistance: 0.02)
        let items = [candidate(1, angle: 0), candidate(2, angle: b), candidate(3, angle: c)]
        for includeSimilar in [false, true] {
            let groups = DuplicateGrouping.groups(from: items, includeSimilarShots: includeSimilar)
            XCTAssertEqual(groups.map { Set($0.photoIDs) }, [[2, 3]], "includeSimilarShots=\(includeSimilar)")
            XCTAssertEqual(groups.first?.kind, .nearIdentical)
        }
    }

    func testTightGroupsMergeAsWholeUnitsWhenEveryMemberIsWithinTheWideLimit() {
        let b = angle(forDistance: 0.20)
        let items = [candidate(1, angle: 0), candidate(2, angle: angle(forDistance: 0.02)), candidate(3, angle: b), candidate(4, angle: b + angle(forDistance: 0.02))]
        let groups = DuplicateGrouping.groups(from: items, includeSimilarShots: true)
        XCTAssertEqual(groups.map { Set($0.photoIDs) }, [[1, 2, 3, 4]])
        XCTAssertEqual(groups.first?.kind, .similarShots)
        XCTAssertEqual(DuplicateGrouping.groups(from: items, includeSimilarShots: false).map { Set($0.photoIDs) }, [[1, 2], [3, 4]])
    }

    /// Chain A~B (0.3), B~C (0.3), A~C (~0.6): single linkage would merge all three; complete linkage must not.
    func testCompleteLinkageDoesNotChainABurstIntoOneGiantGroup() {
        let step = angle(forDistance: 0.30)
        let groups = DuplicateGrouping.groups(from: [
            candidate(1, angle: 0), candidate(2, angle: step), candidate(3, angle: 2 * step),
        ], includeSimilarShots: true)
        XCTAssertEqual(groups.count, 1, "only one pair groups; the chain's far end stays out")
        XCTAssertEqual(groups[0].photoIDs.count, 2)
        XCTAssertFalse(groups[0].photoIDs.contains(3) && groups[0].photoIDs.contains(1))
    }

    func testPhotosWithoutAPrintNeverJoinANearGroup() {
        let groups = DuplicateGrouping.groups(from: [candidate(1, angle: 0), candidate(2, angle: nil)], includeSimilarShots: true)
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: exact + near interplay

    func testAnExactGroupJoinsANearGroupAsAWholeAndEveryPhotoIsInAtMostOneGroup() {
        let items = [
            candidate(1, hash: "A", angle: 0), candidate(2, hash: "A", angle: 0),       // exact pair
            candidate(3, angle: angle(forDistance: 0.05)),                               // near-identical to the pair
            candidate(4, angle: angle(forDistance: 0.9)),                                // unrelated
        ]
        let groups = DuplicateGrouping.groups(from: items, includeSimilarShots: false)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].photoIDs), [1, 2, 3], "both exact members ride along into the near group")
        XCTAssertEqual(groups[0].kind, .nearIdentical)
        let all = groups.flatMap(\.photoIDs)
        XCTAssertEqual(all.count, Set(all).count)
    }

    func testAnExactGroupWithNoNearMatchStaysExact() {
        let groups = DuplicateGrouping.groups(from: [
            candidate(1, hash: "A", angle: 0), candidate(2, hash: "A", angle: 0), candidate(3, angle: angle(forDistance: 0.9)),
        ], includeSimilarShots: true)
        XCTAssertEqual(ids(groups), [[1, 2]])
        XCTAssertEqual(groups[0].kind, .exact)
    }

    func testExactGroupsWithoutPrintsStillGroup() {
        let groups = DuplicateGrouping.groups(from: [candidate(1, hash: "A"), candidate(2, hash: "A")], includeSimilarShots: true)
        XCTAssertEqual(ids(groups), [[1, 2]])
    }

    // MARK: determinism and ordering

    func testResultDoesNotDependOnInputOrderAndIsOrderedByKindThenBestID() {
        let items = [
            candidate(10, angle: 0), candidate(11, angle: angle(forDistance: 0.05)),
            candidate(20, hash: "H"), candidate(21, hash: "H"),
            candidate(30, angle: angle(forDistance: 0.9)), candidate(31, angle: angle(forDistance: 0.9) + angle(forDistance: 0.25)),
        ]
        let forward = DuplicateGrouping.groups(from: items, includeSimilarShots: true)
        XCTAssertEqual(forward, DuplicateGrouping.groups(from: items.reversed(), includeSimilarShots: true))
        XCTAssertEqual(forward, DuplicateGrouping.groups(from: items.shuffled(using: &seeded), includeSimilarShots: true))
        XCTAssertEqual(forward.map(\.kind), [.exact, .nearIdentical, .similarShots])
    }

    private var seeded = SeededGenerator(seed: 42)
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
