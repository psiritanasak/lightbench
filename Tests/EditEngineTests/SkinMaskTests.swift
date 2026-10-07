import XCTest
@testable import PhotoApp

final class SkinMaskTests: XCTestCase {
    func testWindowAcceptsTypicalSkinAndTheSpikesSandAndRock() {
        XCTAssertTrue(SkinWindow.contains(224, 172, 140), "light skin")
        XCTAssertTrue(SkinWindow.contains(141, 85, 36), "medium-brown colour (the spike had no darker-skin sample)")
        XCTAssertTrue(SkinWindow.contains(0.80 * 255, 0.62 * 255, 0.45 * 255), "sand (why the window alone is not a detector)")
        XCTAssertTrue(SkinWindow.contains(0.70 * 255, 0.42 * 255, 0.32 * 255), "rock")
    }

    func testWindowRejectsSkyGrassGrayWhiteAndBlack() {
        XCTAssertFalse(SkinWindow.contains(25, 76, 230), "blue sky")
        XCTAssertFalse(SkinWindow.contains(60, 160, 60), "grass")
        XCTAssertFalse(SkinWindow.contains(128, 128, 128), "neutral gray (fails Cb and Cr together)")
        XCTAssertFalse(SkinWindow.contains(255, 255, 255))
        XCTAssertFalse(SkinWindow.contains(0, 0, 0))
    }

    /// One probe per bound, each within 0.01 of its edge and failing ONLY that bound (found by a numeric search), with a matching
    /// just-inside probe: deleting or moving any single bound fails one of these.
    func testEachWindowBoundIsPinnedByAJustOutsideAndJustInsideProbe() {
        XCTAssertFalse(SkinWindow.contains(47, 37, 37), "Y 39.99 (Cb, Cr in range)")
        XCTAssertTrue(SkinWindow.contains(53, 40, 6), "Y 40.01")
        XCTAssertFalse(SkinWindow.contains(104, 101, 0), "Cb 76.99")
        XCTAssertTrue(SkinWindow.contains(149, 78, 0), "Cb 77.02")
        XCTAssertFalse(SkinWindow.contains(90, 16, 39), "Cb 127.01")
        XCTAssertTrue(SkinWindow.contains(99, 16, 42), "Cb 126.99")
        XCTAssertFalse(SkinWindow.contains(47, 38, 32), "Cr 132.99")
        XCTAssertTrue(SkinWindow.contains(51, 47, 10), "Cr 133.01")
        XCTAssertFalse(SkinWindow.contains(104, 13, 19), "Cr 173.01")
        XCTAssertTrue(SkinWindow.contains(107, 18, 12), "Cr 172.99")
    }

    func testWindowLumaFloorExcludesVeryDarkSkinColours() {
        XCTAssertFalse(SkinWindow.contains(30, 18, 12), "Y = 21: under the floor")
        XCTAssertTrue(SkinWindow.contains(90, 55, 40), "Y ~ 63")
    }

    func testWindowRejectsNonFiniteInput() {
        XCTAssertFalse(SkinWindow.contains(.nan, 172, 140))
        XCTAssertFalse(SkinWindow.contains(224, .infinity, 140))
    }

    private func rgba(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] { pixels.flatMap { [$0.0, $0.1, $0.2, 255] } }

    func testCombineIsTheIntersectionAndKeepsPersonCoverage() throws {
        let skin: (UInt8, UInt8, UInt8) = (224, 172, 140), sky: (UInt8, UInt8, UInt8) = (25, 76, 230)
        // person coverage:     255   128    0     255
        // colour:              skin  skin  skin   sky
        let out = try XCTUnwrap(SkinMaskBuilder.combine(person: [255, 128, 0, 255], rgba: rgba([skin, skin, skin, sky]), width: 4, height: 1))
        XCTAssertEqual(out, [255, 128, 0, 0])
    }

    func testCombineEmptyPersonGivesEmptyMask() throws {
        let out = try XCTUnwrap(SkinMaskBuilder.combine(person: [0, 0], rgba: rgba([(224, 172, 140), (224, 172, 140)]), width: 2, height: 1))
        XCTAssertEqual(out, [0, 0])
    }

    func testCombineRejectsMismatchedSizes() {
        XCTAssertNil(SkinMaskBuilder.combine(person: [255], rgba: rgba([(224, 172, 140), (224, 172, 140)]), width: 2, height: 1))
        XCTAssertNil(SkinMaskBuilder.combine(person: [255, 255], rgba: [0, 0, 0, 255], width: 2, height: 1))
        XCTAssertNil(SkinMaskBuilder.combine(person: [], rgba: [], width: 0, height: 0))
    }

    func testColourlessKeepsToneAndDropsEveryColourChange() {
        let n = StyleMath.nudges(id: "builtin:cinema", tone: 0.4, color: 0.6, strength: 1)
        XCTAssertTrue(n.hasColourEffect)
        let c = n.colourless
        XCTAssertEqual(c.contrast, n.contrast)
        XCTAssertEqual(c.shadows, n.shadows)
        XCTAssertEqual(c.highlights, n.highlights)
        XCTAssertEqual(c.saturation, 0)
        XCTAssertEqual(c.vibrance, 0)
        XCTAssertFalse(c.hasTint)
        XCTAssertFalse(c.hasColourEffect)
    }

    func testColourlessClearsAllThreeTintsAndKeepsHighlights() {
        let n = StyleMath.nudges(id: "builtin:honey", tone: 0, color: 0, strength: 1)
        XCTAssertTrue(n.shadowTint.saturation > 0 && n.midTint.saturation > 0 && n.highlightTint.saturation > 0)
        XCTAssertFalse(n.colourless.hasTint)
        var h = StyleNudges.zero
        h.highlights = -0.4
        h.vibrance = 0.2
        XCTAssertEqual(h.colourless.highlights, -0.4)
        XCTAssertEqual(h.colourless.vibrance, 0)
    }

    func testHasColourEffectDetectsSaturationAndVibranceAlone() {
        var s = StyleNudges.zero
        s.saturation = -0.2
        XCTAssertTrue(s.hasColourEffect)
        var v = StyleNudges.zero
        v.vibrance = 0.2
        XCTAssertTrue(v.hasColourEffect)
    }

    func testHasColourEffectIsFalseForToneOnlyAndZero() {
        XCTAssertFalse(StyleNudges.zero.hasColourEffect)
        XCTAssertFalse(StyleMath.nudges(id: "builtin:radiant", tone: 0, color: 0, strength: 0).hasColourEffect)
        var tone = StyleNudges.zero
        tone.contrast = 0.3
        XCTAssertFalse(tone.hasColourEffect)
        XCTAssertTrue(StyleMath.nudges(id: "builtin:blush", tone: 0, color: 0, strength: 1).hasColourEffect, "tint only")
    }

    func testMonochromeFlagIsExactlySilverAndInk() {
        XCTAssertEqual(Set(StyleLibrary.all.filter(\.isMonochrome).map(\.id)), ["builtin:silver", "builtin:ink"])
    }
}
