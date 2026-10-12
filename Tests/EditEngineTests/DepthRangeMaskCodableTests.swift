import XCTest
@testable import PhotoApp

/// `Mask.depthRange` data model: persistence and identity (the pipeline half is `DepthRangeMaskPipelineTests`).
final class DepthRangeMaskCodableTests: XCTestCase {
    private func decode(_ json: String) throws -> EditState { try JSONDecoder().decode(EditState.self, from: Data(json.utf8)) }
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 8, 7, 6])

    private func depthMask(png: Data? = nil, source: String = "embedded", far: Double = 0.3, near: Double = 0.8, feather: Double = 0.4) -> Mask {
        Mask(kind: .depthRange, exposureEV: -1, invertSelection: true,
             depthRasterPNG: png, depthSource: source, depthFarLimit: far, depthNearLimit: near, depthFeather: feather)
    }

    func testRoundTripsEveryDepthField() throws {
        let original = depthMask(png: png, source: DepthSourceTag.model(id: "m", revision: "r1"))
        let data = try JSONEncoder().encode(EditState(masks: [original]))
        let decoded = try JSONDecoder().decode(EditState.self, from: data).masks[0]
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .depthRange)
        XCTAssertEqual(decoded.depthRasterPNG, png)
        XCTAssertEqual(decoded.depthSource, "model:m:r1")
        XCTAssertEqual(decoded.depthFarLimit, 0.3); XCTAssertEqual(decoded.depthNearLimit, 0.8); XCTAssertEqual(decoded.depthFeather, 0.4)
        XCTAssertTrue(decoded.invertSelection)
    }

    func testAnOlderSidecarWithoutDepthFieldsDecodesWithDefaults() throws {
        let m = try decode(#"{ "masks": [{ "kind": "depthRange", "exposureEV": 1 }] }"#).masks[0]
        XCTAssertEqual(m.kind, .depthRange)
        XCTAssertNil(m.depthRasterPNG)
        XCTAssertEqual(m.depthSource, "")
        XCTAssertEqual(m.depthFarLimit, 0.5); XCTAssertEqual(m.depthNearLimit, 1); XCTAssertEqual(m.depthFeather, 0.1)
        // A non-depth mask decodes the same defaults and is unaffected.
        let other = try decode(#"{ "masks": [{ "kind": "brush" }] }"#).masks[0]
        XCTAssertNil(other.depthRasterPNG)
    }

    /// A corrupt blob or a type-mismatched scalar must cost only that field, never the sidecar.
    func testCorruptDepthFieldsDoNotDiscardTheSidecar() throws {
        let state = try decode(#"{ "exposureEV": 1.5, "masks": [{ "kind": "depthRange", "depthRasterPNG": "%%%not base64%%%", "depthSource": 7, "depthFarLimit": "far", "depthNearLimit": [1], "depthFeather": {} }] }"#)
        XCTAssertEqual(state.exposureEV, 1.5)
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].kind, .depthRange)
        XCTAssertNil(state.masks[0].depthRasterPNG)
        XCTAssertEqual(state.masks[0].depthSource, "")
        XCTAssertEqual(state.masks[0].depthFarLimit, 0.5); XCTAssertEqual(state.masks[0].depthNearLimit, 1); XCTAssertEqual(state.masks[0].depthFeather, 0.1)
    }

    /// An id-less mask gets a deterministic fallback id that depends on EVERY depth field (so two visibly different masks never collide).
    func testFallbackIdDependsOnEveryDepthFieldAndIsStable() throws {
        func id(_ m: Mask) throws -> UUID {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditState(masks: [m]))) as! [String: Any]
            var masks = json["masks"] as! [[String: Any]]
            masks[0].removeValue(forKey: "id")
            json["masks"] = masks
            return try JSONDecoder().decode(EditState.self, from: JSONSerialization.data(withJSONObject: json)).masks[0].id
        }
        let base = depthMask(png: png)
        let reference = try id(base)
        XCTAssertEqual(try id(base), reference, "the same bytes always decode to the same id")
        for variant in [depthMask(png: png, far: 0.31), depthMask(png: png, near: 0.81), depthMask(png: png, feather: 0.41), depthMask(png: png, source: "embedded2"),
                        depthMask(png: Data(png + [1])), depthMask(png: nil)] {
            XCTAssertNotEqual(try id(variant), reference)
        }
        var otherKind = base; otherKind.kind = .subject
        XCTAssertNotEqual(try id(otherKind), reference, "the kind is part of the identity")
    }

    func testAMaskWithoutARasterIsNotTreatedAsHavingDepthAndKeepsAdjustmentIdentityRules() {
        XCTAssertNil(depthMask(png: nil).depthRasterPNG)
        XCTAssertFalse(depthMask().isIdentity, "-1 EV is an adjustment")
        XCTAssertTrue(Mask(kind: .depthRange).isIdentity, "a fresh depth mask adjusts nothing yet")
    }
}
