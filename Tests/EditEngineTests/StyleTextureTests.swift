import XCTest
@testable import PhotoApp

final class StyleTextureTests: XCTestCase {
    func testThreeTexturesWithOwnTitlesAndStableIds() {
        XCTAssertEqual(StyleTexture.allCases.map(\.id), ["soft", "glow", "film"])
        XCTAssertEqual(StyleTexture.allCases.map(\.title), ["Soft", "Glow", "Film"])
    }

    func testDetailIdentityIsNoTextureAndGrainOffWhateverTheAmount() {
        XCTAssertTrue(StyleMath.isDetailIdentity(texture: "", grain: false))
        XCTAssertFalse(StyleMath.isDetailIdentity(texture: "soft", grain: false))
        XCTAssertFalse(StyleMath.isDetailIdentity(texture: "", grain: true))
        XCTAssertFalse(StyleMath.isDetailIdentity(texture: "from-a-newer-build", grain: false), "an unknown id is kept, not identity")
        for amount in [0.0, 0.3, 1.0] {
            XCTAssertTrue(StyleMath.detailNudges(texture: "", amount: amount, grain: false).isZero)
        }
    }

    func testEachTextureMapsToItsOwnDocumentedNudges() {
        let soft = StyleMath.detailNudges(texture: "soft", amount: 1, grain: false)
        XCTAssertEqual(soft, StyleDetailNudges(texture: -0.4, clarity: -0.1))
        let glow = StyleMath.detailNudges(texture: "glow", amount: 1, grain: false)
        XCTAssertEqual(glow, StyleDetailNudges(clarity: -0.05, glow: 1.0))
        let film = StyleMath.detailNudges(texture: "film", amount: 1, grain: false)
        XCTAssertEqual(film, StyleDetailNudges(texture: 0.2, sharpness: 0.15))
        XCTAssertLessThan(soft.texture, 0, "Soft smooths"); XCTAssertGreaterThan(film.texture, 0, "Film crisps")
        XCTAssertGreaterThan(glow.glow, 0)
    }

    func testAmountScalesEveryOutputExactlyLinearlyAndZeroIsNothing() {
        for kind in StyleTexture.allCases {
            let full = StyleMath.detailNudges(texture: kind.id, amount: 1, grain: false)
            let half = StyleMath.detailNudges(texture: kind.id, amount: 0.5, grain: false)
            XCTAssertEqual(half.texture, full.texture / 2, accuracy: 1e-12, kind.title)
            XCTAssertEqual(half.clarity, full.clarity / 2, accuracy: 1e-12, kind.title)
            XCTAssertEqual(half.sharpness, full.sharpness / 2, accuracy: 1e-12, kind.title)
            XCTAssertEqual(half.glow, full.glow / 2, accuracy: 1e-12, kind.title)
            XCTAssertTrue(StyleMath.detailNudges(texture: kind.id, amount: 0, grain: false).isZero, kind.title)
        }
    }

    func testGrainToggleIsIndependentOfTheTextureAndOfItsAmount() {
        XCTAssertEqual(StyleMath.detailNudges(texture: "", amount: 0, grain: true).grain, StyleMath.toggleGrainAmount)
        for kind in StyleTexture.allCases {
            let on = StyleMath.detailNudges(texture: kind.id, amount: 0.3, grain: true)
            let off = StyleMath.detailNudges(texture: kind.id, amount: 0.3, grain: false)
            XCTAssertEqual(on.grain, StyleMath.toggleGrainAmount, kind.title)
            XCTAssertEqual(off.grain, 0, kind.title)
            var withoutGrain = on; withoutGrain.grain = 0
            XCTAssertEqual(withoutGrain, off, "the toggle adds grain and changes nothing else")
        }
    }

    func testNonFiniteAndOutOfRangeAmountsAndUnknownIdsAreSafe() {
        XCTAssertTrue(StyleMath.detailNudges(texture: "soft", amount: .nan, grain: false).isZero)
        XCTAssertTrue(StyleMath.detailNudges(texture: "soft", amount: .infinity, grain: false).isZero)
        XCTAssertEqual(StyleMath.detailNudges(texture: "soft", amount: 9, grain: false), StyleMath.detailNudges(texture: "soft", amount: 1, grain: false))
        XCTAssertTrue(StyleMath.detailNudges(texture: "soft", amount: -3, grain: false).isZero)
        XCTAssertEqual(StyleMath.detailNudges(texture: "soft", amount: .nan, grain: true).grain, StyleMath.toggleGrainAmount,
                       "a broken amount does not switch Grain off")
        XCTAssertTrue(StyleMath.detailNudges(texture: "from-a-newer-build", amount: 1, grain: false).isZero)
    }
}
