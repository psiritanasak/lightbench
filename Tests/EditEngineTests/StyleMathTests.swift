import XCTest
@testable import PhotoApp

final class StyleLibraryTests: XCTestCase {
    func testTheLibraryHasFiveUndertoneAndNineMoodPresetsWithOwnNames() {
        XCTAssertEqual(StyleLibrary.undertone.count, 5)
        XCTAssertEqual(StyleLibrary.mood.count, 9)
        XCTAssertEqual(StyleLibrary.all.map(\.name), ["Frost", "True", "Blush", "Honey", "Copper",
                                                     "Vivid", "Clean", "Radiant", "Cinema", "Hush", "Hearth", "Haze", "Silver", "Ink"])
        let apple = ["Cool Rose", "Neutral", "Rose Gold", "Gold", "Amber", "Standard", "Vibrant", "Natural", "Luminous", "Dramatic",
                     "Quiet", "Cozy", "Cosy", "Ethereal", "Muted B&W", "Stark B&W"]
        XCTAssertTrue(Set(StyleLibrary.all.map(\.name)).isDisjoint(with: apple), "our own names, not Apple's")
    }

    func testIdsAreUniqueBuiltinSlugsAndLookUpByID() {
        let ids = StyleLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for preset in StyleLibrary.all {
            XCTAssertTrue(preset.id.hasPrefix(StyleLibrary.idPrefix))
            XCTAssertEqual(StyleLibrary.preset(for: preset.id), preset)
        }
        XCTAssertNil(StyleLibrary.preset(for: ""))
        XCTAssertNil(StyleLibrary.preset(for: "builtin:nope"))
        XCTAssertEqual(StyleLibrary.presets(in: .undertone), StyleLibrary.undertone)
        XCTAssertEqual(StyleLibrary.presets(in: .mood), StyleLibrary.mood)
    }

    func testEveryNumberIsFiniteAndInRange() {
        for p in StyleLibrary.all {
            for v in [p.contrast, p.shadows, p.highlights, p.saturation, p.vibrance] {
                XCTAssertTrue(v.isFinite && (-1...1).contains(v), "\(p.name)")
            }
            for tint in [p.shadowTint, p.midTint, p.highlightTint] {
                XCTAssertTrue(tint.hue.isFinite && (0..<360).contains(tint.hue), "\(p.name) hue")
                XCTAssertTrue((0...1).contains(tint.saturation), "\(p.name) saturation")
            }
        }
    }

    func testEveryPresetActuallyDoesSomething() {
        for p in StyleLibrary.all {
            XCTAssertFalse(StyleMath.nudges(id: p.id, tone: 0, color: 0, strength: 1).isZero, p.name)
        }
    }

    func testTheMonochromeMoodsUseSaturationMinusOneNotTheBWToggle() {
        for slug in ["silver", "ink"] {
            XCTAssertEqual(StyleLibrary.preset(for: "builtin:\(slug)")?.saturation, -1)
        }
        XCTAssertEqual(StyleLibrary.all.filter { $0.saturation == -1 }.count, 2)
    }
}

final class StyleMathTests: XCTestCase {
    func testIdentityIsNoPresetAndACentredPadWhateverTheStrength() {
        XCTAssertTrue(StyleMath.isIdentity(id: "", tone: 0, color: 0))
        XCTAssertFalse(StyleMath.isIdentity(id: "builtin:vivid", tone: 0, color: 0))
        XCTAssertFalse(StyleMath.isIdentity(id: "", tone: 0.01, color: 0))
        XCTAssertFalse(StyleMath.isIdentity(id: "", tone: 0, color: -0.01))
        XCTAssertTrue(StyleMath.isIdentity(id: "", tone: .nan, color: .infinity), "non-finite pad = centre, as in nudges")
        XCTAssertFalse(StyleMath.isIdentity(id: "builtin:from-a-newer-build", tone: 0, color: 0), "an unknown id is kept, not identity")
        for strength in [0.0, 0.3, 1.0] {
            XCTAssertTrue(StyleMath.nudges(id: "", tone: 0, color: 0, strength: strength).isZero)
        }
    }

    func testPadMovesShadowsContrastVibranceAndSaturationWithTheDocumentedWeights() {
        let up = StyleMath.nudges(id: "", tone: 1, color: 0, strength: 1)
        XCTAssertEqual(up.shadows, StyleMath.toneShadowWeight, accuracy: 1e-12)
        XCTAssertEqual(up.contrast, StyleMath.toneContrastWeight, accuracy: 1e-12)
        XCTAssertEqual(up.vibrance, 0); XCTAssertEqual(up.saturation, 0)
        let right = StyleMath.nudges(id: "", tone: 0, color: 1, strength: 1)
        XCTAssertEqual(right.vibrance, StyleMath.colorVibranceWeight, accuracy: 1e-12)
        XCTAssertEqual(right.saturation, StyleMath.colorSaturationWeight, accuracy: 1e-12)
        XCTAssertEqual(right.shadows, 0)
        XCTAssertGreaterThan(StyleMath.colorVibranceWeight, StyleMath.colorSaturationWeight, "Color leans on skin-protecting Vibrance")
    }

    func testPadIsMonotonicAndAntisymmetricAboutTheCentre() {
        var last = -Double.infinity
        for t in stride(from: -1.0, through: 1.0, by: 0.25) {
            let n = StyleMath.nudges(id: "", tone: t, color: 0, strength: 1)
            XCTAssertGreaterThan(n.shadows, last, "shadows strictly increase with Tone")
            last = n.shadows
            let mirrored = StyleMath.nudges(id: "", tone: -t, color: 0, strength: 1)
            XCTAssertEqual(n.shadows, -mirrored.shadows, accuracy: 1e-12)
            XCTAssertEqual(n.contrast, -mirrored.contrast, accuracy: 1e-12)
        }
    }

    /// Every one of the 8 outputs comes from ITS OWN preset slot, and strength scales all of them (all three tints too).
    func testEveryPresetFieldMapsToItsOwnOutputAndStrengthScalesAllEightExactly() {
        for p in StyleLibrary.all {
            let full = StyleMath.nudges(id: p.id, tone: 0, color: 0, strength: 1)
            XCTAssertEqual(full, StyleNudges(contrast: p.contrast, shadows: p.shadows, highlights: p.highlights, saturation: p.saturation,
                                             vibrance: p.vibrance, shadowTint: p.shadowTint, midTint: p.midTint, highlightTint: p.highlightTint), p.name)
            let half = StyleMath.nudges(id: p.id, tone: 0, color: 0, strength: 0.5)
            XCTAssertEqual(half.contrast, p.contrast / 2, accuracy: 1e-12, p.name)
            XCTAssertEqual(half.shadows, p.shadows / 2, accuracy: 1e-12, p.name)
            XCTAssertEqual(half.highlights, p.highlights / 2, accuracy: 1e-12, p.name)
            XCTAssertEqual(half.saturation, p.saturation / 2, accuracy: 1e-12, p.name)
            XCTAssertEqual(half.vibrance, p.vibrance / 2, accuracy: 1e-12, p.name)
            for (got, want) in [(half.shadowTint, p.shadowTint), (half.midTint, p.midTint), (half.highlightTint, p.highlightTint)] {
                XCTAssertEqual(got.saturation, want.saturation / 2, accuracy: 1e-12, p.name)
                if want.saturation > 0 { XCTAssertEqual(got.hue, want.hue, p.name) }
            }
        }
    }

    /// Strength stays linear even when preset + pad overflow the slider range (the dead-zone bug: clamping AFTER scaling).
    func testStrengthIsStillLinearWhenPresetPlusPadOverflowTheRange() {
        // Ink saturation -1 plus color -1 (-0.25) = -1.25 before clamping.
        for s in [0.2, 0.5, 0.8, 0.9, 1.0] {
            XCTAssertEqual(StyleMath.nudges(id: "builtin:ink", tone: 0, color: -1, strength: s).saturation, -s, accuracy: 1e-12, "strength \(s)")
        }
    }

    func testContrastFallsWithToneAndVibranceAndSaturationRiseWithColor() {
        var lastContrast = Double.infinity, lastVibrance = -Double.infinity, lastSaturation = -Double.infinity
        for v in stride(from: -1.0, through: 1.0, by: 0.25) {
            let tone = StyleMath.nudges(id: "", tone: v, color: 0, strength: 1)
            let color = StyleMath.nudges(id: "", tone: 0, color: v, strength: 1)
            XCTAssertLessThan(tone.contrast, lastContrast); lastContrast = tone.contrast
            XCTAssertGreaterThan(color.vibrance, lastVibrance); lastVibrance = color.vibrance
            XCTAssertGreaterThan(color.saturation, lastSaturation); lastSaturation = color.saturation
        }
    }

    func testStrengthScalesTheWholeStyleLinearlyAndZeroIsNothing() {
        let full = StyleMath.nudges(id: "builtin:cinema", tone: 0.4, color: -0.6, strength: 1)
        let half = StyleMath.nudges(id: "builtin:cinema", tone: 0.4, color: -0.6, strength: 0.5)
        XCTAssertEqual(half.contrast, full.contrast / 2, accuracy: 1e-12)
        XCTAssertEqual(half.shadows, full.shadows / 2, accuracy: 1e-12)
        XCTAssertEqual(half.vibrance, full.vibrance / 2, accuracy: 1e-12)
        XCTAssertEqual(half.shadowTint.saturation, full.shadowTint.saturation / 2, accuracy: 1e-12)
        XCTAssertEqual(half.shadowTint.hue, full.shadowTint.hue, "strength never changes a tint's hue")
        XCTAssertTrue(StyleMath.nudges(id: "builtin:cinema", tone: 0.4, color: -0.6, strength: 0).isZero)
    }

    func testPresetAndPadAddThenClampSoAStackedStyleCannotExceedTheSliderRange() {
        let n = StyleMath.nudges(id: "builtin:ink", tone: 0, color: -1, strength: 1)   // preset -1 + pad -0.25
        XCTAssertEqual(n.saturation, -1)
        let big = StyleMath.nudges(id: "builtin:vivid", tone: 1, color: 1, strength: 1)
        XCTAssertEqual(big.vibrance, 0.30 + StyleMath.colorVibranceWeight, accuracy: 1e-12)   // 0.8: below the clamp, additive
    }

    func testNonFiniteInputsContributeNothingAndOutOfRangeInputsClamp() {
        XCTAssertTrue(StyleMath.nudges(id: "builtin:vivid", tone: 0, color: 0, strength: .nan).isZero)
        XCTAssertTrue(StyleMath.nudges(id: "builtin:vivid", tone: 0, color: 0, strength: .infinity).isZero)
        XCTAssertEqual(StyleMath.nudges(id: "", tone: .nan, color: .infinity, strength: 1), .zero)
        XCTAssertEqual(StyleMath.nudges(id: "", tone: 5, color: -5, strength: 1), StyleMath.nudges(id: "", tone: 1, color: -1, strength: 1))
        XCTAssertEqual(StyleMath.nudges(id: "builtin:vivid", tone: 0, color: 0, strength: 7), StyleMath.nudges(id: "builtin:vivid", tone: 0, color: 0, strength: 1))
        XCTAssertTrue(StyleMath.nudges(id: "builtin:vivid", tone: 0, color: 0, strength: -3).isZero)
    }

    func testAnUnknownPresetIdBehavesAsNoPresetButThePadStillApplies() {
        let unknown = StyleMath.nudges(id: "builtin:from-a-newer-build", tone: 0.5, color: 0, strength: 1)
        XCTAssertEqual(unknown, StyleMath.nudges(id: "", tone: 0.5, color: 0, strength: 1))
        XCTAssertFalse(unknown.isZero)
        XCTAssertFalse(unknown.hasTint)
    }

    func testTintsComeOnlyFromPresetsThatHaveThem() {
        XCTAssertTrue(StyleMath.nudges(id: "builtin:honey", tone: 0, color: 0, strength: 1).hasTint)
        XCTAssertFalse(StyleMath.nudges(id: "builtin:vivid", tone: 0, color: 0, strength: 1).hasTint)
        XCTAssertFalse(StyleMath.nudges(id: "", tone: 1, color: 1, strength: 1).hasTint, "the pad never tints")
    }
}
