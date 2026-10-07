import XCTest
@testable import PhotoApp

/// The persisted/propagated shape of Styles v3 "Protect skin" (fields, Codable, Presets/Paste, Compare, identity). Rendering is
/// covered separately; none of this touches Vision.
final class StyleSkinProtectionStateTests: XCTestCase {
    private let png = Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    private func protected(amount: Double = 0.6) -> EditState {
        var s = EditState()
        s.styleID = "builtin:honey"
        s.styleProtectSkin = true
        s.styleProtectAmount = amount
        s.styleSkinMaskPNG = png
        s.styleSkinMaskRevision = 1
        return s
    }

    func testDefaultsAreOffFullAmountNoRaster() {
        let s = EditState()
        XCTAssertFalse(s.styleProtectSkin)
        XCTAssertEqual(s.styleProtectAmount, 1.0)
        XCTAssertNil(s.styleSkinMaskPNG)
        XCTAssertNil(s.styleSkinMaskRevision)
    }

    func testCodableRoundTripKeepsEveryField() throws {
        let decoded = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(protected()))
        XCTAssertTrue(decoded.styleProtectSkin)
        XCTAssertEqual(decoded.styleProtectAmount, 0.6)
        XCTAssertEqual(decoded.styleSkinMaskPNG, png)
        XCTAssertEqual(decoded.styleSkinMaskRevision, 1)
        XCTAssertEqual(decoded, protected())
    }

    func testAbsentKeysDecodeToDefaultsIncludingTheNonZeroIdentityAmount() throws {
        let old = try JSONDecoder().decode(EditState.self, from: Data(#"{ "exposureEV": 1 }"#.utf8))
        XCTAssertFalse(old.styleProtectSkin)
        XCTAssertEqual(old.styleProtectAmount, 1.0, "the non-zero identity default must survive an absent key")
        XCTAssertNil(old.styleSkinMaskPNG)
    }

    func testWrongTypesNeverDiscardTheRestOfTheSidecar() throws {
        let json = #"{ "exposureEV": 1, "styleProtectSkin": "yes", "styleProtectAmount": "high", "styleSkinMaskPNG": 7, "styleSkinMaskRevision": "one" }"#
        let wrong = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        XCTAssertEqual(wrong.exposureEV, 1)
        XCTAssertFalse(wrong.styleProtectSkin)
        XCTAssertEqual(wrong.styleProtectAmount, 1.0)
        XCTAssertNil(wrong.styleSkinMaskPNG)
        XCTAssertNil(wrong.styleSkinMaskRevision)
    }

    func testAMistypedAmountFallsBackToTheNonZeroIdentityNotZero() throws {
        let wrong = try JSONDecoder().decode(EditState.self, from: Data(#"{ "styleProtectSkin": true, "styleProtectAmount": "high" }"#.utf8))
        XCTAssertEqual(wrong.styleProtectAmount, 1.0, "a wrong type must not silently become 0 (protection off)")
        XCTAssertTrue(wrong.styleProtectSkin)
    }

    func testProtectionCountsAsAnEditAndIsNotARawRedecode() {
        var raster = EditState(); raster.styleSkinMaskPNG = png
        XCTAssertFalse(raster.isEffectivelyIdentity, "a stranded raster must not read as an untouched photo")
        var flag = EditState(); flag.styleProtectSkin = true
        XCTAssertFalse(flag.isEffectivelyIdentity)
        for state in [raster, flag, protected()] { XCTAssertFalse(state.requiresRawRedecode(comparedTo: EditState())) }
    }

    func testComparisonOriginalClearsAllFourFields() {
        let original = protected().comparisonOriginal()
        XCTAssertFalse(original.styleProtectSkin)
        XCTAssertEqual(original.styleProtectAmount, 1)
        XCTAssertNil(original.styleSkinMaskPNG)
        XCTAssertNil(original.styleSkinMaskRevision)
    }

    func testPresetsAndPasteCarryNoSkinProtectionAndLeaveTheTargetsOwn() {
        var target = protected(amount: 0.3)
        target.styleSkinMaskPNG = Data([1, 2, 3])
        var source = protected(amount: 0.9)
        source.styleID = "builtin:copper"
        let result = source.applyingPreset(onto: target)
        XCTAssertEqual(result.styleID, "builtin:copper", "the style itself travels")
        XCTAssertTrue(result.styleProtectSkin)
        XCTAssertEqual(result.styleProtectAmount, 0.3, "the target's own amount")
        XCTAssertEqual(result.styleSkinMaskPNG, Data([1, 2, 3]), "the target's own raster, never the source's")
        XCTAssertEqual(result.styleSkinMaskRevision, 1)
        let bare = source.applyingPreset(onto: EditState())
        XCTAssertFalse(bare.styleProtectSkin)
        XCTAssertNil(bare.styleSkinMaskPNG, "a target without a raster does not inherit the source's")
    }

    func testHistorySummaryMentionsTheStyleForAProtectionChange() {
        XCTAssertTrue(EditStateDiff.summary(from: EditState(), to: { var s = EditState(); s.styleProtectAmount = 0.5; return s }()).contains("Style"))
    }
}
