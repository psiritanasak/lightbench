import XCTest
@testable import PhotoApp

/// `Mask.subject` data model (AI Subject mask, commit 1): persistence and identity only — the
/// pipeline/UI halves are tested where they live.
final class SubjectMaskCodableTests: XCTestCase {
    private func decode(_ json: String) throws -> EditState {
        try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    func testSubjectMaskRoundTripsThroughCodable() throws {
        let original = Mask(kind: .subject, exposureEV: -1, subjectMaskPNG: png, subjectMaskRevision: 1, invertSelection: true)
        let data = try JSONEncoder().encode(EditState(masks: [original]))
        let decoded = try JSONDecoder().decode(EditState.self, from: data).masks[0]
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .subject)
        XCTAssertEqual(decoded.subjectMaskPNG, png)
        XCTAssertEqual(decoded.subjectMaskRevision, 1)
        XCTAssertTrue(decoded.invertSelection)
    }

    func testPreSubjectSidecarDecodesWithDefaults() throws {
        let state = try decode(#"{ "masks": [{ "kind": "brush", "exposureEV": 1 }] }"#)
        XCTAssertNil(state.masks[0].subjectMaskPNG)
        XCTAssertNil(state.masks[0].subjectMaskRevision)
        XCTAssertFalse(state.masks[0].invertSelection)
    }

    /// A corrupt blob (not base64) must cost only the raster, never the whole sidecar.
    func testCorruptSubjectBlobDoesNotDiscardTheSidecar() throws {
        let state = try decode(#"{ "exposureEV": 1.5, "masks": [{ "kind": "subject", "subjectMaskPNG": "%%%not base64%%%", "subjectMaskRevision": "x", "invertSelection": 7 }] }"#)
        XCTAssertEqual(state.exposureEV, 1.5)
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].kind, .subject)
        XCTAssertNil(state.masks[0].subjectMaskPNG)
        XCTAssertNil(state.masks[0].subjectMaskRevision)
        XCTAssertFalse(state.masks[0].invertSelection)
    }

    func testSubjectKindIsNotAdjustmentIdentityByItself() {
        // The raster/invert are selection data, like geometry: excluded from `isIdentity`.
        XCTAssertTrue(Mask(kind: .subject, subjectMaskPNG: png, invertSelection: true).isIdentity)
    }

    // MARK: Fallback ids (id-less masks in a hand-edited sidecar)

    private func fallbackID(_ fields: String) throws -> UUID {
        try decode(#"{ "masks": [{ "kind": "subject"\#(fields) }] }"#).masks[0].id
    }

    func testFallbackIDDiffersByPNGBytesInvertAndRevision() throws {
        let a = try fallbackID(#", "subjectMaskPNG": "AQIDBA==""#)
        let b = try fallbackID(#", "subjectMaskPNG": "AQIDBQ==""#)
        let inverted = try fallbackID(#", "subjectMaskPNG": "AQIDBA==", "invertSelection": true"#)
        let revised = try fallbackID(#", "subjectMaskPNG": "AQIDBA==", "subjectMaskRevision": 2"#)
        let none = try fallbackID("")
        let empty = try fallbackID(#", "subjectMaskPNG": """#)
        XCTAssertEqual(Set([a, b, inverted, revised, none, empty]).count, 6)
    }

    func testFallbackIDIsStableAcrossDecodes() throws {
        XCTAssertEqual(try fallbackID(#", "subjectMaskPNG": "AQIDBA==""#), try fallbackID(#", "subjectMaskPNG": "AQIDBA==""#))
    }

    func testSubjectAndRadialWithSameFieldsGetDifferentIds() throws {
        let radial = try decode(#"{ "masks": [{}] }"#).masks[0].id
        XCTAssertNotEqual(radial, try fallbackID(""))
    }
}
