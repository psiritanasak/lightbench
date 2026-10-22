import XCTest
@testable import PhotoApp

final class StackPlannerTests: XCTestCase {
    private func vec(angle: Float) -> [Float] {
        var v = [Float](repeating: 0, count: FeaturePrintVector.elementCount)
        v[0] = cos(angle); v[1] = sin(angle)
        return v
    }

    private func angle(forDistance distance: Float) -> Float { 2 * asin(distance / 2) }

    private func cand(
        _ id: Int64, t: Double? = 0, dist: Float? = 0, rating: Int = 0, size: Int64 = 1000,
        base: String = "", folder: String = "/f"
    ) -> StackCandidate {
        StackCandidate(
            id: id, captureDate: t, featurePrint: dist.map { vec(angle: angle(forDistance: $0)) }, rating: rating,
            fileSize: size, importedAt: Date(timeIntervalSince1970: Double(id)), baseName: base.isEmpty ? "img\(id)" : base, folder: folder
        )
    }

    private func sets(_ plan: StackPlan) -> [Set<Int64>] { plan.proposals.map { Set($0.memberIDs) } }

    func testBurstWithinGapStacksAndLargerGapSplits() {
        let plan = StackPlanner.plan([cand(1, t: 100), cand(2, t: 102), cand(3, t: 104.5), cand(4, t: 120), cand(5, t: 121)])
        XCTAssertEqual(Set(sets(plan)), Set([[1, 2, 3], [4, 5]].map { Set<Int64>($0) }))
    }

    func testGapMeasuredToPreviousMemberNotToTheFirst() {
        // 100, 102.9, 105.8: each step <= 3 s, so one burst (print distances all 0).
        let plan = StackPlanner.plan([cand(1, t: 100), cand(2, t: 102.9), cand(3, t: 105.8)])
        XCTAssertEqual(sets(plan), [Set<Int64>([1, 2, 3])])
    }

    func testGapJustOverTheLimitSplits() {
        let plan = StackPlanner.plan([cand(1, t: 100), cand(2, t: 103.01)])
        XCTAssertTrue(plan.proposals.isEmpty)
    }

    func testCustomGapParameter() {
        let plan = StackPlanner.plan([cand(1, t: 100), cand(2, t: 108)], params: .init(maxGapSeconds: 10))
        XCTAssertEqual(sets(plan), [Set<Int64>([1, 2])])
    }

    func testCompleteLinkageDoesNotChain() {
        // A-B 0.3, B-C 0.3, A-C ~0.6 (angles add up): C must not join A and B.
        let a = angle(forDistance: 0.3)
        let photos = [
            StackCandidate(id: 1, captureDate: 0, featurePrint: vec(angle: 0)),
            StackCandidate(id: 2, captureDate: 1, featurePrint: vec(angle: a)),
            StackCandidate(id: 3, captureDate: 2, featurePrint: vec(angle: 2 * a))
        ]
        let plan = StackPlanner.plan(photos)
        XCTAssertEqual(sets(plan), [Set<Int64>([1, 2])])
    }

    func testDissimilarPhotoStartsNewBurstThatLaterPhotosCanJoin() {
        let far = angle(forDistance: 0.9)
        let photos = [
            StackCandidate(id: 1, captureDate: 0, featurePrint: vec(angle: 0)),
            StackCandidate(id: 2, captureDate: 1, featurePrint: vec(angle: far)),
            StackCandidate(id: 3, captureDate: 2, featurePrint: vec(angle: far))
        ]
        XCTAssertEqual(sets(StackPlanner.plan(photos)), [Set<Int64>([2, 3])])
    }

    func testSimilarityLimitIsInclusive() {
        let ok = StackPlanner.plan([cand(1, t: 0, dist: 0), cand(2, t: 1, dist: 0.34)])
        XCTAssertEqual(sets(ok), [Set<Int64>([1, 2])])
        let tooFar = StackPlanner.plan([cand(1, t: 0, dist: 0), cand(2, t: 1, dist: 0.36)])
        XCTAssertTrue(tooFar.proposals.isEmpty)
    }

    func testPhotosWithoutPrintsOnlyStackWithinOneSecond() {
        XCTAssertEqual(sets(StackPlanner.plan([cand(1, t: 0, dist: nil), cand(2, t: 1, dist: nil)])), [Set<Int64>([1, 2])])
        XCTAssertTrue(StackPlanner.plan([cand(1, t: 0, dist: nil), cand(2, t: 2, dist: nil)]).proposals.isEmpty)
        // One side with a print and the other without is also time-only.
        XCTAssertTrue(StackPlanner.plan([cand(1, t: 0, dist: 0), cand(2, t: 2, dist: nil)]).proposals.isEmpty)
        XCTAssertEqual(sets(StackPlanner.plan([cand(1, t: 0, dist: 0), cand(2, t: 1, dist: nil)])), [Set<Int64>([1, 2])])
    }

    func testNoCaptureDateIsNeverStackedByTime() {
        let plan = StackPlanner.plan([cand(1, t: nil), cand(2, t: nil), cand(3, t: 5), cand(4, t: .nan)])
        XCTAssertTrue(plan.proposals.isEmpty)
    }

    func testRawJpgPairStacksWithoutPrints() {
        let plan = StackPlanner.plan([
            cand(1, t: 50, dist: nil, base: "dsc_1"), cand(2, t: 50, dist: nil, base: "dsc_1"),
            cand(3, t: 900, dist: nil, base: "dsc_2")
        ])
        XCTAssertEqual(sets(plan), [Set<Int64>([1, 2])])
    }

    func testUndatedSameNameFilesDoNotPair() {
        let plan = StackPlanner.plan([cand(1, t: nil, dist: nil, base: "dsc_1"), cand(2, t: nil, dist: nil, base: "dsc_1")])
        XCTAssertTrue(plan.proposals.isEmpty)
        let oneDated = StackPlanner.plan([cand(1, t: nil, dist: nil, base: "dsc_1"), cand(2, t: 5, dist: nil, base: "dsc_1")])
        XCTAssertTrue(oneDated.proposals.isEmpty)
    }

    func testPairingDoesNotChain() {
        // Same name at 0, 3 and 6 s (no prints): no unit forms, and 3 s is outside the 1 s no-print burst gap too.
        let plan = StackPlanner.plan([
            cand(1, t: 0, dist: nil, base: "a"), cand(2, t: 3, dist: nil, base: "a"), cand(3, t: 6, dist: nil, base: "a")
        ])
        XCTAssertTrue(plan.proposals.isEmpty)
    }

    func testPairGapIsFixedNotTheBurstGap() {
        // Same name 2 s apart: inside the burst gap (3 s) but outside the pair gap (1 s), so no pair; with prints they stack as a burst.
        let loose = StackPlanner.plan([cand(1, t: 0, dist: nil, base: "a"), cand(2, t: 2, dist: nil, base: "a")])
        XCTAssertTrue(loose.proposals.isEmpty)
    }

    func testPairsStackFirstThenJoinTheBurst() {
        // 1+2 are one shot (RAW+JPG); 3 follows 2 s later: the burst is all three.
        let plan = StackPlanner.plan([cand(1, t: 10, base: "dsc_1"), cand(2, t: 10, base: "dsc_1"), cand(3, t: 12)])
        XCTAssertEqual(sets(plan), [Set<Int64>([1, 2, 3])])
    }

    func testSameBaseNameInDifferentFoldersIsNotAPair() {
        let plan = StackPlanner.plan([cand(1, t: nil, dist: nil, base: "a", folder: "/x"), cand(2, t: nil, dist: nil, base: "a", folder: "/y")])
        XCTAssertTrue(plan.proposals.isEmpty)
    }

    func testSameBaseNameFarApartInTimeIsNotAFakePair() {
        let plan = StackPlanner.plan([cand(1, t: 0, dist: 0, base: "img_1"), cand(2, t: 100_000, dist: 0, base: "img_1")])
        XCTAssertTrue(plan.proposals.isEmpty)
    }

    func testCoverIsTheBestMember() {
        let plan = StackPlanner.plan([cand(1, t: 0, rating: 1), cand(2, t: 1, rating: 4), cand(3, t: 2, rating: 4, size: 5000)])
        XCTAssertEqual(plan.proposals.first?.coverID, 3)
        XCTAssertEqual(plan.proposals.first?.memberIDs, [3, 2, 1])
    }

    func testOrderIndependenceAndDeterminism() {
        var photos: [StackCandidate] = []
        for i in 1...30 {
            let time: Double = Double(i / 3) + Double(i % 3) * 0.5
            let distance: Float = Float(i % 4) * 0.05
            photos.append(cand(Int64(i), t: time, dist: distance))
        }
        photos += [cand(40, t: nil), cand(41, t: 5, base: "p"), cand(42, t: 5, base: "p")]
        let reference = StackPlanner.plan(photos)
        XCTAssertFalse(reference.proposals.isEmpty)
        for seed in 0..<6 {
            var rng = StackTestRNG(seed: UInt64(seed + 1))
            XCTAssertEqual(StackPlanner.plan(photos.shuffled(using: &rng)), reference)
        }
        XCTAssertEqual(StackPlanner.plan(photos), reference)
    }

    func testDuplicateIdsAreIgnored() {
        let plan = StackPlanner.plan([cand(1, t: 0), cand(1, t: 0), cand(2, t: 1)])
        XCTAssertEqual(plan.proposals.first?.memberIDs.sorted(), [1, 2])
    }

    func testBurstSizeCapStartsANewBurst() {
        let photos = (1...7).map { cand(Int64($0), t: Double($0) * 0.5) }
        let plan = StackPlanner.plan(photos, params: .init(maximumBurstUnits: 3))
        XCTAssertEqual(sets(plan), [Set<Int64>([1, 2, 3]), Set<Int64>([4, 5, 6])]) // 7 is alone
    }

    func testCandidateCapKeepsTheNewestAndCountsTheRest() {
        let photos = (1...6).map { cand(Int64($0), t: Double($0) * 0.5) }
        let plan = StackPlanner.plan(photos, params: .init(maximumCandidatesPerRun: 4))
        XCTAssertEqual(plan.deferred, 2)
        XCTAssertEqual(sets(plan), [Set<Int64>([3, 4, 5, 6])])
        XCTAssertEqual(plan.coveredPhotoCount, 4)
    }

    func testPairingComparesWithTheFirstMemberNotChained() {
        // No prints, so the 1 s no-print burst gap also applies: 0 and 0.9 pair; 0, 1.5, 3 do not pair (1.5 > 1 from the first)
        // and are further than 1 s apart as a burst too.
        let near = StackPlanner.plan([cand(1, t: 0, dist: nil, base: "a"), cand(2, t: 0.9, dist: nil, base: "a")])
        XCTAssertEqual(sets(near), [Set<Int64>([1, 2])])
        let chained = StackPlanner.plan([cand(1, t: 0, dist: nil, base: "a"), cand(2, t: 1.5, dist: nil, base: "a"), cand(3, t: 3, dist: nil, base: "a")])
        XCTAssertTrue(chained.proposals.isEmpty)
    }

    func testPairUnitIsFormedAgainstTheFirstMemberEvenWhenPrintsDisagree() {
        // Same name at 0, 0.9, 1.8 s. #3 is 1.8 s from the first, so it is NOT in the pair unit; its print is far from the pair's, so
        // the burst rejects it. (Chaining the unit through #2 would force all three together.)
        let far = angle(forDistance: 0.9)
        let photos = [
            StackCandidate(id: 1, captureDate: 0, featurePrint: vec(angle: 0), baseName: "a", folder: "/f"),
            StackCandidate(id: 2, captureDate: 0.9, featurePrint: vec(angle: 0), baseName: "a", folder: "/f"),
            StackCandidate(id: 3, captureDate: 1.8, featurePrint: vec(angle: far), baseName: "a", folder: "/f")
        ]
        XCTAssertEqual(sets(StackPlanner.plan(photos)), [Set<Int64>([1, 2])])
    }

    func testGapIsMeasuredFromTheLatestDateOfThePreviousUnit() {
        // A pair at 0 and 0.9 (one unit) then a photo at 3.5: 3.5 is more than 3 s from 0 but only 2.6 s from 0.9.
        let plan = StackPlanner.plan([
            cand(1, t: 0, base: "a"), cand(2, t: 0.9, base: "a"), cand(3, t: 3.5)
        ])
        XCTAssertEqual(sets(plan), [Set<Int64>([1, 2, 3])])
    }

    func testNonFiniteDatesNextToDatedUnitsAreNeverStacked() {
        let plan = StackPlanner.plan([cand(1, t: 100), cand(2, t: .nan), cand(3, t: .infinity), cand(4, t: -.infinity), cand(5, t: 101)])
        XCTAssertEqual(sets(plan), [Set<Int64>([1, 5])])
    }

    func testDuplicateIdsWithDifferingDataResolveDeterministically() {
        let early = cand(1, t: 100)
        var late = cand(1, t: 500)
        late.fileSize = 1
        let other = cand(2, t: 101)
        let forward = StackPlanner.plan([early, late, other])
        let backward = StackPlanner.plan([other, late, early])
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(sets(forward), [Set<Int64>([1, 2])]) // the earlier-dated candidate wins
        let undated = StackPlanner.plan([cand(1, t: nil), early, other])
        XCTAssertEqual(sets(undated), [Set<Int64>([1, 2])]) // a dated candidate beats a missing date
    }

    func testNewPhotoCloseToTheFirstMemberButFarFromAMiddleOneIsRejected() {
        let a = angle(forDistance: 0.3)
        let photos = [
            StackCandidate(id: 1, captureDate: 0, featurePrint: vec(angle: 0)),
            StackCandidate(id: 2, captureDate: 1, featurePrint: vec(angle: a)),
            StackCandidate(id: 3, captureDate: 2, featurePrint: vec(angle: -a)) // 0.3 from #1, about 0.6 from #2
        ]
        XCTAssertEqual(sets(StackPlanner.plan(photos)), [Set<Int64>([1, 2])])
    }

    func testPrintlessPhotoBetweenPrintedOnesStillChecksTheirPrints() {
        let near = StackPlanner.plan([cand(1, t: 0, dist: 0), cand(2, t: 1, dist: nil), cand(3, t: 2, dist: 0)])
        XCTAssertEqual(sets(near), [Set<Int64>([1, 2, 3])])
        let far = angle(forDistance: 0.9)
        let photos = [
            StackCandidate(id: 1, captureDate: 0, featurePrint: vec(angle: 0)),
            StackCandidate(id: 2, captureDate: 1, featurePrint: nil),
            StackCandidate(id: 3, captureDate: 2, featurePrint: vec(angle: far))
        ]
        XCTAssertEqual(sets(StackPlanner.plan(photos)), [Set<Int64>([1, 2])])
    }

    func testNoPrintGapIsTheSmallerOfTheTwoLimits() {
        let params = StackPlanner.Params(maxGapSeconds: 0.5, maxGapWithoutPrintSeconds: 5)
        XCTAssertTrue(StackPlanner.plan([cand(1, t: 0, dist: nil), cand(2, t: 1, dist: nil)], params: params).proposals.isEmpty)
        XCTAssertEqual(sets(StackPlanner.plan([cand(1, t: 0, dist: nil), cand(2, t: 0.4, dist: nil)], params: params)), [Set<Int64>([1, 2])])
    }

    func testPlannedIDsAreExactlyTheConsideredCandidates() {
        let photos = (1...6).map { cand(Int64($0), t: Double($0) * 0.5) }
        XCTAssertEqual(StackPlanner.plan(photos).plannedIDs, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(StackPlanner.plan(photos, params: .init(maximumCandidatesPerRun: 4)).plannedIDs, [3, 4, 5, 6])
        XCTAssertEqual(StackPlanner.plan([photos[0], photos[0]]).plannedIDs, [1])
    }

    func testProposalCoverIsTheFirstMemberAndSafeWhenEmpty() {
        XCTAssertEqual(StackProposal(memberIDs: [7, 3]).coverID, 7)
        XCTAssertNil(StackProposal(memberIDs: []).coverID)
    }

    func testMismatchedPrintLengthsNeverStack() {
        let short = StackCandidate(id: 2, captureDate: 1, featurePrint: [1, 0, 0])
        let plan = StackPlanner.plan([cand(1, t: 0, dist: 0), short])
        XCTAssertTrue(plan.proposals.isEmpty)
    }
}

struct StackTestRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
