import XCTest
@testable import PhotoApp

/// `EditState.resettingLookAndStyle()` / `isLookAndStyleAtIdentity`: the Looks tab's one list of look + style fields.
final class EditStateLookStyleResetTests: XCTestCase {
    private let png = Data([1, 2, 3, 4])

    /// Every look/style field, each as a mutation that moves it away from its default.
    private let mutations: [(String, (inout EditState) -> Void)] = [
        ("lookID", { $0.lookID = "builtin:x" }),
        ("lookIntensity", { $0.lookIntensity = 0.5 }),
        ("styleID", { $0.styleID = "builtin:honey" }),
        ("styleTone", { $0.styleTone = 0.3 }),
        ("styleColor", { $0.styleColor = -0.3 }),
        ("styleStrength", { $0.styleStrength = 0.4 }),
        ("styleTexture", { $0.styleTexture = "film" }),
        ("styleTextureAmount", { $0.styleTextureAmount = 0.4 }),
        ("styleGrain", { $0.styleGrain = true }),
        ("styleProtectSkin", { $0.styleProtectSkin = true }),
        ("styleProtectAmount", { $0.styleProtectAmount = 0.4 }),
        ("styleSkinMaskPNG", { $0.styleSkinMaskPNG = Data([9]) }),
        ("styleSkinMaskRevision", { $0.styleSkinMaskRevision = 1 }),
    ]

    func testEachLookOrStyleFieldAloneMakesTheStateNotAtIdentityAndResetClearsIt() {
        XCTAssertTrue(EditState().isLookAndStyleAtIdentity)
        for (name, mutate) in mutations {
            var s = EditState()
            mutate(&s)
            XCTAssertFalse(s.isLookAndStyleAtIdentity, name)
            XCTAssertEqual(s.resettingLookAndStyle(), EditState(), "\(name): reset returns to the defaults")
            XCTAssertTrue(s.resettingLookAndStyle().isLookAndStyleAtIdentity, name)
        }
    }

    /// A NEW look*/style* stored property must be added to `resettingLookAndStyle()` — this fails until it is (and until the
    /// `mutations` table above names it), instead of letting Reset Look & Style silently leave it behind.
    func testTheListMatchesEveryLookAndStyleStoredProperty() {
        let labels = Set(Mirror(reflecting: EditState()).children.compactMap(\.label).filter { $0.hasPrefix("look") || $0.hasPrefix("style") })
        XCTAssertEqual(labels, Set(mutations.map(\.0)))
    }

    func testResetLeavesEveryOtherFieldUntouched() {
        var s = EditState()
        s.exposureEV = 0.7; s.contrast = -0.2; s.cropInsetLeft = 0.1; s.flipHorizontal = true; s.blackAndWhite = true
        s.toneCurvePoints = [ToneCurvePoint(x: 0.5, y: 0.6)]
        s.masks = [Mask()]; s.rawDecoderVersionPin = "pin"; s.grain = 0.3; s.redEyePoints = [RedEyePoint(x: 0.1, y: 0.2)]
        for (_, mutate) in mutations { mutate(&s) }
        let r = s.resettingLookAndStyle()
        XCTAssertEqual(r.exposureEV, 0.7); XCTAssertEqual(r.contrast, -0.2); XCTAssertEqual(r.cropInsetLeft, 0.1)
        XCTAssertTrue(r.flipHorizontal); XCTAssertTrue(r.blackAndWhite)
        XCTAssertEqual(r.toneCurvePoints, s.toneCurvePoints); XCTAssertEqual(r.masks, s.masks)
        XCTAssertEqual(r.rawDecoderVersionPin, "pin"); XCTAssertEqual(r.grain, 0.3); XCTAssertEqual(r.redEyePoints, s.redEyePoints)
        XCTAssertTrue(r.isLookAndStyleAtIdentity)
        XCTAssertFalse(r.isEffectivelyIdentity, "the other edits remain")
    }

    func testResetIsIdempotent() {
        var s = EditState(); for (_, m) in mutations { m(&s) }
        XCTAssertEqual(s.resettingLookAndStyle().resettingLookAndStyle(), s.resettingLookAndStyle())
    }

    func testComparisonOriginalStillClearsLookAndStyleThroughTheSharedList() {
        var s = EditState(); for (_, m) in mutations { m(&s) }
        XCTAssertTrue(s.comparisonOriginal().isLookAndStyleAtIdentity)
    }
}
