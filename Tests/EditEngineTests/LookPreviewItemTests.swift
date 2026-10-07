import XCTest
@testable import PhotoApp

final class LookPreviewItemTests: XCTestCase {
    func testLooksListIsNoneThenBuiltInsThenImported() {
        let user = LookLibrary.UserLook(id: "user:abc", name: "Mine", cube: BuiltInLooks.cube(id: BuiltInLooks.all[0].id)!)
        let items = LookPreviewItem.looks(userLooks: [user])
        XCTAssertEqual(items.count, 1 + BuiltInLooks.all.count + 1)
        XCTAssertEqual(items.first, LookPreviewItem(kind: .look, id: "", name: "None"))
        XCTAssertEqual(items.dropFirst().prefix(BuiltInLooks.all.count).map(\.id), BuiltInLooks.all.map(\.id))
        XCTAssertEqual(items.last, LookPreviewItem(kind: .look, id: "user:abc", name: "Mine"))
        XCTAssertTrue(items.allSatisfy { $0.kind == .look })
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "ids are unique")
    }

    func testStylesListIsNoneThenEveryPresetInLibraryOrder() {
        let items = LookPreviewItem.styles()
        XCTAssertEqual(items.count, 1 + StyleLibrary.all.count)
        XCTAssertEqual(items.first?.id, "")
        XCTAssertEqual(items.dropFirst().map(\.id), StyleLibrary.all.map(\.id))
        XCTAssertEqual(items.dropFirst().map(\.name), StyleLibrary.all.map(\.name))
        XCTAssertTrue(items.allSatisfy { $0.kind == .style })
    }

    func testApplyingChangesExactlyOneIdAndKeepsEverythingElse() {
        var s = EditState()
        s.lookID = "builtin:a"; s.lookIntensity = 0.4; s.styleID = "builtin:honey"; s.styleStrength = 0.7; s.styleTone = 0.2
        s.styleTexture = "film"; s.exposureEV = 0.5
        let look = LookPreviewItem(kind: .look, id: "builtin:b", name: "B").applying(to: s)
        var expectedLook = s; expectedLook.lookID = "builtin:b"
        XCTAssertEqual(look, expectedLook)
        let style = LookPreviewItem(kind: .style, id: "builtin:copper", name: "Copper").applying(to: s)
        var expectedStyle = s; expectedStyle.styleID = "builtin:copper"
        XCTAssertEqual(style, expectedStyle)
    }

    /// The None cells reproduce `selectLook("")` / `selectStyle("")`: no phantom edit is left behind.
    func testNoneCellsResetTheOrphanedStrengthExactlyLikeTheClickHandlers() {
        var s = EditState()
        s.lookID = "builtin:a"; s.lookIntensity = 0.4
        let noLook = LookPreviewItem(kind: .look, id: "", name: "None").applying(to: s)
        XCTAssertEqual(noLook.lookID, "")
        XCTAssertEqual(noLook.lookIntensity, 1, "selectLook(\"\") also restores the intensity")

        var centred = EditState()
        centred.styleID = "builtin:honey"; centred.styleStrength = 0.4
        let noStyleCentred = LookPreviewItem(kind: .style, id: "", name: "None").applying(to: centred)
        XCTAssertEqual(noStyleCentred.styleID, "")
        XCTAssertEqual(noStyleCentred.styleStrength, 1, "pad centred: the strength would be an invisible edit, so it resets")

        var offCentre = centred
        offCentre.styleTone = 0.3
        let noStyleOff = LookPreviewItem(kind: .style, id: "", name: "None").applying(to: offCentre)
        XCTAssertEqual(noStyleOff.styleStrength, 0.4, "pad off-centre: the strength still scales the pad, so it is kept")
        XCTAssertEqual(noStyleOff.styleTone, 0.3)
    }

    func testNonNoneCellsKeepTheCurrentIntensityAndStrength() {
        var s = EditState()
        s.lookIntensity = 0.4; s.styleStrength = 0.4
        XCTAssertEqual(LookPreviewItem(kind: .look, id: "builtin:b", name: "B").applying(to: s).lookIntensity, 0.4)
        XCTAssertEqual(LookPreviewItem(kind: .style, id: "builtin:copper", name: "C").applying(to: s).styleStrength, 0.4)
    }

    func testPreviewStateClearsOnlyTheThreeLocalEdits() {
        var s = EditState()
        s.masks = [Mask()]; s.retouchSpots = [RetouchSpot()]; s.redEyePoints = [RedEyePoint(x: 0.1, y: 0.2)]
        s.exposureEV = 0.5; s.cropInsetLeft = 0.1; s.blackAndWhite = true; s.grain = 0.2; s.lookID = "builtin:a"
        let p = LookPreviewItem.previewState(from: s)
        XCTAssertTrue(p.masks.isEmpty); XCTAssertTrue(p.retouchSpots.isEmpty); XCTAssertTrue(p.redEyePoints.isEmpty)
        var restored = p
        restored.masks = s.masks; restored.retouchSpots = s.retouchSpots; restored.redEyePoints = s.redEyePoints
        XCTAssertEqual(restored, s, "nothing else changed")
    }

    func testGridKeysIgnoreTheirOwnIdAndLocalEditsButSeeEverythingElse() {
        var s = EditState()
        s.lookID = "builtin:a"; s.styleID = "builtin:honey"
        // Picking a look does not make the Looks grid stale, but does make the Style grid stale (previews stack on the look).
        var pickedLook = s; pickedLook.lookID = "builtin:b"
        XCTAssertEqual(LookPreviewItem.looksGridKey(for: s), LookPreviewItem.looksGridKey(for: pickedLook))
        XCTAssertNotEqual(LookPreviewItem.stylesGridKey(for: s), LookPreviewItem.stylesGridKey(for: pickedLook))
        // And the other way round.
        var pickedStyle = s; pickedStyle.styleID = "builtin:copper"
        XCTAssertEqual(LookPreviewItem.stylesGridKey(for: s), LookPreviewItem.stylesGridKey(for: pickedStyle))
        XCTAssertNotEqual(LookPreviewItem.looksGridKey(for: s), LookPreviewItem.looksGridKey(for: pickedStyle))
        // Intensity, pad, strength and any global edit make both stale.
        for mutate in [{ (e: inout EditState) in e.lookIntensity = 0.3 }, { $0.styleStrength = 0.3 }, { $0.styleTone = 0.4 },
                       { $0.exposureEV = 0.5 }, { $0.cropInsetLeft = 0.1 }] as [(inout EditState) -> Void] {
            var m = s; mutate(&m)
            XCTAssertNotEqual(LookPreviewItem.looksGridKey(for: s), LookPreviewItem.looksGridKey(for: m))
            XCTAssertNotEqual(LookPreviewItem.stylesGridKey(for: s), LookPreviewItem.stylesGridKey(for: m))
        }
        // Local edits never make either grid stale.
        var local = s; local.masks = [Mask()]; local.retouchSpots = [RetouchSpot()]; local.redEyePoints = [RedEyePoint(x: 0, y: 0)]
        XCTAssertEqual(LookPreviewItem.looksGridKey(for: s), LookPreviewItem.looksGridKey(for: local))
        XCTAssertEqual(LookPreviewItem.stylesGridKey(for: s), LookPreviewItem.stylesGridKey(for: local))
    }

    func testImportedLooksAreExactlyTheNonBuiltInNonEmptyLookIDs() {
        let user = LookLibrary.UserLook(id: "user:abc", name: "Mine", cube: BuiltInLooks.cube(id: BuiltInLooks.all[0].id)!)
        let items = LookPreviewItem.looks(userLooks: [user])
        XCTAssertEqual(items.filter(\.isImportedLook).map(\.id), ["user:abc"])
        XCTAssertFalse(LookPreviewItem(kind: .look, id: "", name: "None").isImportedLook)
        XCTAssertFalse(LookPreviewItem(kind: .look, id: BuiltInLooks.all[0].id, name: "x").isImportedLook)
        XCTAssertFalse(LookPreviewItem(kind: .style, id: "builtin:honey", name: "Honey").isImportedLook)
        XCTAssertFalse(LookPreviewItem(kind: .style, id: "user:oops", name: "x").isImportedLook, "styles are never imported looks")
    }
}
