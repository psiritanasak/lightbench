import XCTest
@testable import PhotoApp

final class RetouchSpotTests: XCTestCase {
    private func decode(_ json: String) throws -> EditState {
        try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
    }

    // MARK: Codable

    func testRoundTripKeepsEverything() throws {
        var spot = RetouchSpot()
        spot.x = 0.3; spot.y = 0.7; spot.radius = 0.02; spot.sourceDX = -0.05; spot.sourceDY = 0.04
        spot.mode = .clone; spot.feather = 0.2; spot.opacity = 0.6
        var state = EditState(); state.retouchSpots = [spot]
        let decoded = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.retouchSpots, [spot])
    }

    func testAbsentKeyDecodesToNoSpots() throws {
        XCTAssertEqual(try decode(#"{ "exposureEV": 1 }"#).retouchSpots, [])
    }

    func testMissingFieldsTakeTheirDefaults() throws {
        let spot = try decode(#"{ "retouchSpots": [ { "x": 0.2, "y": 0.4 } ] }"#).retouchSpots[0]
        XCTAssertEqual(spot.x, 0.2)
        XCTAssertEqual(spot.radius, 0.015)
        XCTAssertEqual(spot.mode, .heal)
        XCTAssertEqual(spot.opacity, 1)
        XCTAssertEqual(spot.feather, 0.5)
    }

    func testOneCorruptSpotIsDroppedNotTheSidecarNorItsNeighbours() throws {
        let state = try decode(#"{ "exposureEV": 2, "retouchSpots": [ { "x": 0.1 }, { "x": "bad" }, { "x": 0.9 } ] }"#)
        XCTAssertEqual(state.exposureEV, 2)
        XCTAssertEqual(state.retouchSpots.map(\.x), [0.1, 0.9])
    }

    func testMistypedOrUnknownModeFallsBackToHealWithoutDroppingTheSpot() throws {
        let spots = try decode(#"{ "retouchSpots": [ { "mode": "stamp" }, { "mode": 5 }, { "mode": "clone" } ] }"#).retouchSpots
        XCTAssertEqual(spots.map(\.mode), [.heal, .heal, .clone])
    }

    func testNonFiniteAndOverCapSpotsAreDroppedOnDecode() throws {
        // Limitation: a NaN/infinity cannot be produced through JSON here, so the `isFinite` filter on decode is only
        // covered by the direct `isFinite` check below; the cap is exercised end to end.
        var spot = RetouchSpot(); spot.x = .nan
        XCTAssertFalse(spot.isFinite)
        let many = (0..<80).map { _ in #"{ "x": 0.5 }"# }.joined(separator: ",")
        XCTAssertEqual(try decode("{ \"retouchSpots\": [\(many)] }").retouchSpots.count, EditState.maxRetouchSpots)
    }

    func testIDlessSpotsDecodeToEqualValuesAndDifferentSpotsToDifferentIDs() throws {
        let json = #"{ "retouchSpots": [ { "x": 0.2, "y": 0.4 }, { "x": 0.3, "y": 0.4 } ] }"#
        let a = try decode(json).retouchSpots, b = try decode(json).retouchSpots
        XCTAssertEqual(a, b, "two decodes of the same bytes must be equal (render cache / history no-op guard)")
        XCTAssertNotEqual(a[0].id, a[1].id)
        let clone = try decode(#"{ "retouchSpots": [ { "x": 0.2, "y": 0.4, "mode": "clone" } ] }"#).retouchSpots[0]
        XCTAssertNotEqual(clone.id, a[0].id, "mode feeds the fallback id")
    }

    func testIdenticalIDlessSpotsGetUniqueButDeterministicIDs() throws {
        let many = (0..<5).map { _ in #"{ "x": 0.5 }"# }.joined(separator: ",")
        let json = "{ \"retouchSpots\": [\(many)] }"
        let a = try decode(json).retouchSpots, b = try decode(json).retouchSpots
        XCTAssertEqual(Set(a.map(\.id)).count, 5, "ForEach/delete-by-id need distinct ids")
        XCTAssertEqual(a, b, "and the same bytes must still decode to equal values")
    }

    func testClampedKeepsValuesInRange() {
        var s = RetouchSpot()
        s.x = -3; s.y = 9; s.radius = 5; s.feather = -1; s.opacity = 7
        let c = s.clamped
        XCTAssertEqual([c.x, c.y, c.feather, c.opacity], [0, 1, 0, 1])
        XCTAssertEqual(c.radius, RetouchSpot.radiusRange.upperBound)
        s.radius = 0
        XCTAssertEqual(s.clamped.radius, RetouchSpot.radiusRange.lowerBound)
    }

    // MARK: EditState plumbing

    func testSpotsCountAsAnEditAndAreClearedByTheComparisonOriginal() {
        XCTAssertTrue(EditState().isEffectivelyIdentity)
        var state = EditState(); state.retouchSpots = [RetouchSpot()]
        XCTAssertFalse(state.isEffectivelyIdentity)
        XCTAssertTrue(state.comparisonOriginal().retouchSpots.isEmpty)
    }

    func testPresetsNeitherCopyNorClearSpots() {
        var source = EditState(); source.retouchSpots = [RetouchSpot()]
        var target = EditState(); var own = RetouchSpot(); own.x = 0.11; target.retouchSpots = [own]
        XCTAssertEqual(source.applyingPreset(onto: target).retouchSpots, [own], "target keeps its own spots, gets none of the source's")
        XCTAssertTrue(source.applyingPreset(onto: EditState()).retouchSpots.isEmpty)
        XCTAssertTrue(source.applyingPreset(onto: .identity).retouchSpots.isEmpty, "saving a preset must not capture spots")
    }

    func testGeometrySamplingStateCarriesNoSpots() {
        var state = EditState(); state.retouchSpots = [RetouchSpot()]
        XCTAssertTrue(state.geometryOnlySamplingState().retouchSpots.isEmpty)
    }
}
