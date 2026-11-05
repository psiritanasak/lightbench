import XCTest
@testable import PhotoApp

final class FaceSimilarityTests: XCTestCase {
    /// A 768-float print that is `value` along one axis: the distance between two of these is |a - b|.
    private func print(_ value: Float, axis: Int = 0) -> Data {
        var v = [Float](repeating: 0, count: FeaturePrintVector.elementCount)
        v[axis] = value
        return v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func candidate(_ id: Int64, _ data: Data) -> FaceSimilarity.Candidate { .init(id: id, featurePrint: data) }

    func testACandidateMatchesWhenItsNearestReferenceIsWithinTheLimitInclusive() {
        let result = FaceSimilarity.similar(references: [print(0), print(10)],
                                            candidates: [candidate(1, print(0.3)), candidate(2, print(0.45)), candidate(3, print(5)), candidate(4, print(9.7)), candidate(5, print(10.46))],
                                            limit: 0.45)
        XCTAssertEqual(result.matches, [1, 2, 4], "min over references; 0.45 is inside, 0.46 outside; candidate order kept")
    }

    func testFacesWithoutAUsablePrintAreSkippedAndCountedNeverMatchedAsDistanceZero() {
        let result = FaceSimilarity.similar(references: [print(0)],
                                            candidates: [candidate(1, Data()), candidate(2, Data([1, 2, 3])), candidate(3, print(0.1))], limit: 0.45)
        XCTAssertEqual(result.matches, [3])
        XCTAssertEqual(result.withoutPrint, 2)
    }

    func testReferencesWithoutAPrintAreIgnoredAndAllUnusableMeansNoMatches() {
        let some = FaceSimilarity.similar(references: [Data(), print(0)], candidates: [candidate(1, print(0.2))], limit: 0.45)
        XCTAssertEqual(some.matches, [1])
        XCTAssertEqual(some.referencesWithoutPrint, 1)
        let none = FaceSimilarity.similar(references: [Data()], candidates: [candidate(1, print(0.2)), candidate(2, Data())], limit: 0.45)
        XCTAssertTrue(none.matches.isEmpty, "an empty reference must not match everything")
        XCTAssertEqual(none.referencesWithoutPrint, 1)
        XCTAssertEqual(none.withoutPrint, 1)
    }

    func testStrengthLimitsAreOrderedAndNormalStaysUnderTheGroupingThreshold() {
        XCTAssertLessThan(FaceSimilarityStrength.strict.limit, FaceSimilarityStrength.normal.limit)
        XCTAssertLessThan(FaceSimilarityStrength.normal.limit, FaceSimilarityStrength.loose.limit)
        // Retuned 2026-11-05: Normal stays at or under the grouping threshold and under the first different person in the probe (0.44).
        XCTAssertLessThanOrEqual(FaceSimilarityStrength.normal.limit, FaceGrouping.Thresholds().assign)
        XCTAssertLessThan(FaceSimilarityStrength.normal.limit, 0.44)
    }
}
