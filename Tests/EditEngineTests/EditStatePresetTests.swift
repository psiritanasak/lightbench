import XCTest
@testable import PhotoApp

/// Verifies `EditState.applyingPreset(onto:)` — Phase 5 slice 2. The two
/// invariants this design rests on, mirroring `EditStateComparisonOriginalTests`
/// for the opposite-direction method: every color/tone field is copied FROM
/// the preset, and every geometry field (plus `redEyePoints`) is preserved
/// from the TARGET, unaffected by whatever the preset's own geometry was.
final class EditStatePresetTests: XCTestCase {
    /// A fully non-identity `EditState`, same shape as
    /// `EditStateComparisonOriginalTests.fullyEditedState()` — every
    /// color/tone field pushed away from default, every geometry field
    /// pushed away from default, and a real red-eye point placed.
    private func fullyEditedState() -> EditState {
        var s = EditState()
        // light/tone
        s.exposureEV = 1.5
        s.brightness = 0.3
        s.brilliance = 0.4
        s.contrast = 0.2
        s.curvesHighlights = -0.3
        s.curvesShadows = 0.3
        s.toneCurvePoints = [
            ToneCurvePoint(x: 0, y: 0.05),
            ToneCurvePoint(x: 0.35, y: 0.22),
            ToneCurvePoint(x: 0.7, y: 0.81),
            ToneCurvePoint(x: 1, y: 0.97)
        ]
        s.toneCurvePointsRed = [ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 1, y: 0.9)]
        s.toneCurvePointsGreen = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        s.toneCurvePointsBlue = [ToneCurvePoint(x: 0, y: 0.05), ToneCurvePoint(x: 1, y: 0.95)]
        s.blackPoint = 0.1
        s.levelsBlackPoint = 0.05
        s.levelsWhitePoint = 0.9
        s.levelsGamma = 1.4
        // white balance
        s.whiteBalanceTemperature = 8000
        s.whiteBalanceTint = 20
        // hsl / color
        s.hslHue = 0.2
        s.vibrance = 0.4
        s.hslSaturation = 0.3
        // selective color
        s.selectiveColorRange = 0.7
        s.redHue = 0.1; s.redSaturation = 0.1; s.redLuminance = 0.1
        s.orangeHue = 0.1; s.orangeSaturation = 0.1; s.orangeLuminance = 0.1
        s.yellowHue = 0.1; s.yellowSaturation = 0.1; s.yellowLuminance = 0.1
        s.greenHue = 0.1; s.greenSaturation = 0.1; s.greenLuminance = 0.1
        s.aquaHue = 0.1; s.aquaSaturation = 0.1; s.aquaLuminance = 0.1
        s.blueHue = 0.1; s.blueSaturation = 0.1; s.blueLuminance = 0.1
        s.purpleHue = 0.1; s.purpleSaturation = 0.1; s.purpleLuminance = 0.1
        s.magentaHue = 0.1; s.magentaSaturation = 0.1; s.magentaLuminance = 0.1
        // black & white + effects
        s.blackAndWhite = true
        s.shadowHue = 210; s.shadowSaturation = 0.6; s.shadowLuminance = -0.3
        s.midtoneHue = 30; s.midtoneSaturation = 0.4; s.midtoneLuminance = 0.2
        s.highlightHue = 50; s.highlightSaturation = 0.5; s.highlightLuminance = 0.1
        s.vignetteStrength = 0.5
        s.vignetteRadius = 0.7
        s.clarity = 0.4
        s.sharpness = 0.6
        s.noiseReduction = 0.3
        s.grain = 0.2
        // red-eye
        s.redEyeSize = 0.8
        s.redEyeStrength = 0.9
        s.redEyePoints = [RedEyePoint(x: 0.3, y: 0.4), RedEyePoint(x: 0.6, y: 0.5)]
        // masks
        s.masks = [
            Mask(
                centerX: 0.3, centerY: 0.6, radiusX: 0.2, radiusY: 0.15,
                rotationDegrees: 10, feather: 0.4,
                exposureEV: 0.5, contrast: 0.1, highlights: -0.2, shadows: 0.2,
                clarity: 0.25, saturation: 0.3, temperature: 200, tint: -10
            )
        ]
        // point color
        s.pointColors = [
            PointColor(hasTarget: true, targetHue: 30, targetSaturation: 0.5, range: 0.4, hue: 0.2, saturation: 0.1, luminance: -0.1)
        ]
        // geometry
        s.straightenAngle = 12
        s.verticalPerspective = 0.2
        s.horizontalPerspective = -0.15
        s.flipHorizontal = true
        s.flipVertical = true
        s.cropInsetTop = 0.1
        s.cropInsetBottom = 0.1
        s.cropInsetLeft = 0.2
        s.cropInsetRight = 0.15
        // RAW-native
        s.boostAmount = 0.3
        s.rawExposureEV = 0.6
        s.shadowBoostScale = 0.2
        s.rawWhiteBalanceNeutralPoints = [RawNeutralPoint(x: 0.35, y: 0.65)]
        s.rawLuminanceNoiseReductionAdjust = 0.15
        s.rawColorNoiseReductionScale = 0.45
        s.rawSharpnessScale = 0.75
        s.rawContrastAdjust = 0.25
        s.rawDetailAdjust = 1.1
        s.rawMoireReductionAdjust = 0.35
        s.rawDecoderVersionPin = "7"
        return s
    }

    func testColorAndToneFieldsAreCopiedFromThePreset() {
        let preset = fullyEditedState()
        let target = EditState.identity

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.exposureEV, preset.exposureEV)
        XCTAssertEqual(result.brightness, preset.brightness)
        XCTAssertEqual(result.brilliance, preset.brilliance)
        XCTAssertEqual(result.contrast, preset.contrast)
        XCTAssertEqual(result.curvesHighlights, preset.curvesHighlights)
        XCTAssertEqual(result.curvesShadows, preset.curvesShadows)
        // COPIED by a preset, unlike `redEyePoints`/`masks`. A tone curve is
        // a look, not a placement — see `applyingPreset(onto:)`.
        XCTAssertEqual(result.toneCurvePoints, preset.toneCurvePoints)
        XCTAssertEqual(result.toneCurvePointsRed, preset.toneCurvePointsRed)
        XCTAssertEqual(result.toneCurvePointsGreen, preset.toneCurvePointsGreen)
        XCTAssertEqual(result.toneCurvePointsBlue, preset.toneCurvePointsBlue)
        XCTAssertEqual(result.blackPoint, preset.blackPoint)
        XCTAssertEqual(result.levelsBlackPoint, preset.levelsBlackPoint)
        XCTAssertEqual(result.levelsWhitePoint, preset.levelsWhitePoint)
        XCTAssertEqual(result.levelsGamma, preset.levelsGamma)
        XCTAssertEqual(result.whiteBalanceTemperature, preset.whiteBalanceTemperature)
        XCTAssertEqual(result.whiteBalanceTint, preset.whiteBalanceTint)
        XCTAssertEqual(result.hslHue, preset.hslHue)
        XCTAssertEqual(result.vibrance, preset.vibrance)
        XCTAssertEqual(result.hslSaturation, preset.hslSaturation)
        XCTAssertEqual(result.selectiveColorRange, preset.selectiveColorRange)
        XCTAssertEqual(result.redHue, preset.redHue)
        XCTAssertEqual(result.magentaLuminance, preset.magentaLuminance)
        XCTAssertEqual(result.blackAndWhite, preset.blackAndWhite)
        XCTAssertEqual(result.shadowHue, preset.shadowHue)
        XCTAssertEqual(result.shadowSaturation, preset.shadowSaturation)
        XCTAssertEqual(result.shadowLuminance, preset.shadowLuminance)
        XCTAssertEqual(result.midtoneHue, preset.midtoneHue)
        XCTAssertEqual(result.midtoneSaturation, preset.midtoneSaturation)
        XCTAssertEqual(result.midtoneLuminance, preset.midtoneLuminance)
        XCTAssertEqual(result.highlightHue, preset.highlightHue)
        XCTAssertEqual(result.highlightSaturation, preset.highlightSaturation)
        XCTAssertEqual(result.highlightLuminance, preset.highlightLuminance)
        XCTAssertEqual(result.vignetteStrength, preset.vignetteStrength)
        XCTAssertEqual(result.vignetteRadius, preset.vignetteRadius)
        XCTAssertEqual(result.clarity, preset.clarity)
        XCTAssertEqual(result.sharpness, preset.sharpness)
        XCTAssertEqual(result.noiseReduction, preset.noiseReduction)
        XCTAssertEqual(result.grain, preset.grain)
        XCTAssertEqual(result.redEyeSize, preset.redEyeSize)
        XCTAssertEqual(result.redEyeStrength, preset.redEyeStrength)
    }

    /// The real regression guard: a preset must NEVER move the target
    /// photo's crop/straighten/perspective/flip, or reposition its red-eye
    /// correction markers — both are specific to the TARGET photo's own
    /// composition, not part of a reusable "look".
    func testTargetsGeometryAndRedEyePointsSurviveUntouched() {
        let preset = fullyEditedState() // preset's OWN geometry is non-identity too
        var target = EditState.identity
        target.straightenAngle = -7
        target.verticalPerspective = 0.05
        target.horizontalPerspective = -0.05
        target.flipHorizontal = false
        target.flipVertical = true
        target.cropInsetTop = 0.02
        target.cropInsetBottom = 0.03
        target.cropInsetLeft = 0.04
        target.cropInsetRight = 0.01
        target.redEyePoints = [RedEyePoint(x: 0.1, y: 0.9)]

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.straightenAngle, target.straightenAngle)
        XCTAssertEqual(result.verticalPerspective, target.verticalPerspective)
        XCTAssertEqual(result.horizontalPerspective, target.horizontalPerspective)
        XCTAssertEqual(result.flipHorizontal, target.flipHorizontal)
        XCTAssertEqual(result.flipVertical, target.flipVertical)
        XCTAssertEqual(result.cropInsetTop, target.cropInsetTop)
        XCTAssertEqual(result.cropInsetBottom, target.cropInsetBottom)
        XCTAssertEqual(result.cropInsetLeft, target.cropInsetLeft)
        XCTAssertEqual(result.cropInsetRight, target.cropInsetRight)
        XCTAssertEqual(result.redEyePoints, target.redEyePoints)
        XCTAssertNotEqual(
            result.straightenAngle, preset.straightenAngle,
            "sanity check: the preset's own geometry must NOT have leaked through"
        )
    }

    /// Masks join `redEyePoints` in this same guard, for the identical
    /// reason: an ellipse placed on the PRESET's own source photo is
    /// meaningless dropped onto a different target photo.
    func testTargetsMasksSurviveAPreset() {
        let preset = fullyEditedState() // preset's OWN masks are non-empty too
        var target = EditState.identity
        target.masks = [Mask(centerX: 0.1, centerY: 0.9, radiusX: 0.1, radiusY: 0.1)]

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.masks, target.masks)
        XCTAssertNotEqual(
            result.masks, preset.masks,
            "sanity check: the preset's own masks must NOT have leaked through"
        )
    }

    /// Point Color joins `redEyePoints`/`masks` in this same guard, for the
    /// same reason: a color picked from the PRESET's own source photo is
    /// meaningless dropped onto a different target photo.
    func testTargetsPointColorsSurviveAPreset() {
        let preset = fullyEditedState() // preset's OWN pointColors are non-empty too
        var target = EditState.identity
        target.pointColors = [PointColor(hasTarget: true, targetHue: 90, targetSaturation: 0.3)]

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.pointColors, target.pointColors)
        XCTAssertNotEqual(
            result.pointColors, preset.pointColors,
            "sanity check: the preset's own point colors must NOT have leaked through"
        )
    }

    /// Every RAW-native field survives a preset apply as the TARGET's own
    /// value, like geometry — never copied from the preset. Carrying them
    /// would make applying ANY preset trigger a multi-second RAW
    /// re-decode (no other preset field does that) and would silently
    /// set RAW-decode parameters on a non-RAW target. Checked in both
    /// directions: the preset's own (non-default) value must NOT leak
    /// through, and the target's own (different, non-default) value must
    /// survive exactly.
    func testTargetsBoostAmountSurvivesAPreset() {
        let preset = fullyEditedState() // boostAmount = 0.3
        var target = EditState.identity
        target.boostAmount = 0.8

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.boostAmount, target.boostAmount)
        XCTAssertNotEqual(result.boostAmount, preset.boostAmount)
    }

    func testTargetsRawExposureEVSurvivesAPreset() {
        let preset = fullyEditedState() // rawExposureEV = 0.6
        var target = EditState.identity
        target.rawExposureEV = -0.9

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawExposureEV, target.rawExposureEV)
        XCTAssertNotEqual(result.rawExposureEV, preset.rawExposureEV)
    }

    func testTargetsShadowBoostScaleSurvivesAPreset() {
        let preset = fullyEditedState() // shadowBoostScale = 0.2
        var target = EditState.identity
        target.shadowBoostScale = 0.75

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.shadowBoostScale, target.shadowBoostScale)
        XCTAssertNotEqual(result.shadowBoostScale, preset.shadowBoostScale)
    }

    func testTargetsRawWhiteBalanceNeutralPointsSurvivesAPreset() {
        let preset = fullyEditedState() // rawWhiteBalanceNeutralPoints = [(0.35, 0.65)]
        var target = EditState.identity
        target.rawWhiteBalanceNeutralPoints = [RawNeutralPoint(x: 0.1, y: 0.9)]

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawWhiteBalanceNeutralPoints, target.rawWhiteBalanceNeutralPoints)
        XCTAssertNotEqual(result.rawWhiteBalanceNeutralPoints, preset.rawWhiteBalanceNeutralPoints)
    }

    func testTargetsRawLuminanceNoiseReductionAdjustSurvivesAPreset() {
        let preset = fullyEditedState() // rawLuminanceNoiseReductionAdjust = 0.15
        var target = EditState.identity
        target.rawLuminanceNoiseReductionAdjust = 0.65

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawLuminanceNoiseReductionAdjust, target.rawLuminanceNoiseReductionAdjust)
        XCTAssertNotEqual(result.rawLuminanceNoiseReductionAdjust, preset.rawLuminanceNoiseReductionAdjust)
    }

    func testTargetsRawColorNoiseReductionScaleSurvivesAPreset() {
        let preset = fullyEditedState() // rawColorNoiseReductionScale = 0.45
        var target = EditState.identity
        target.rawColorNoiseReductionScale = 0.85

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawColorNoiseReductionScale, target.rawColorNoiseReductionScale)
        XCTAssertNotEqual(result.rawColorNoiseReductionScale, preset.rawColorNoiseReductionScale)
    }

    func testTargetsRawSharpnessScaleSurvivesAPreset() {
        let preset = fullyEditedState() // rawSharpnessScale = 0.75
        var target = EditState.identity
        target.rawSharpnessScale = 0.05

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawSharpnessScale, target.rawSharpnessScale)
        XCTAssertNotEqual(result.rawSharpnessScale, preset.rawSharpnessScale)
    }

    func testTargetsRawContrastAdjustSurvivesAPreset() {
        let preset = fullyEditedState() // rawContrastAdjust = 0.25
        var target = EditState.identity
        target.rawContrastAdjust = -0.4

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawContrastAdjust, target.rawContrastAdjust)
        XCTAssertNotEqual(result.rawContrastAdjust, preset.rawContrastAdjust)
    }

    func testTargetsRawDetailAdjustSurvivesAPreset() {
        let preset = fullyEditedState() // rawDetailAdjust = 1.1
        var target = EditState.identity
        target.rawDetailAdjust = -2.0

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawDetailAdjust, target.rawDetailAdjust)
        XCTAssertNotEqual(result.rawDetailAdjust, preset.rawDetailAdjust)
    }

    func testTargetsRawMoireReductionAdjustSurvivesAPreset() {
        let preset = fullyEditedState() // rawMoireReductionAdjust = 0.35
        var target = EditState.identity
        target.rawMoireReductionAdjust = -0.6

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawMoireReductionAdjust, target.rawMoireReductionAdjust)
        XCTAssertNotEqual(result.rawMoireReductionAdjust, preset.rawMoireReductionAdjust)
    }

    func testTargetsRawDecoderVersionPinSurvivesAPreset() {
        let preset = fullyEditedState() // rawDecoderVersionPin = "7"
        var target = EditState.identity
        target.rawDecoderVersionPin = "6"

        let result = preset.applyingPreset(onto: target)

        XCTAssertEqual(result.rawDecoderVersionPin, target.rawDecoderVersionPin)
        XCTAssertNotEqual(result.rawDecoderVersionPin, preset.rawDecoderVersionPin)
    }

    /// Pins the real "Save Preset" mechanism (`AdjustTabView`'s Save Preset
    /// button calls `document.editState.applyingPreset(onto: .identity)`):
    /// a newly-created preset must never carry the SOURCE photo's masks as
    /// inert dead data, even though the source photo's own state is
    /// non-empty here.
    func testASavedPresetCarriesNoMasks() {
        let currentEditState = fullyEditedState() // masks is non-empty

        let savedPreset = currentEditState.applyingPreset(onto: .identity)

        XCTAssertEqual(savedPreset.masks, [])
    }

    /// Same contract as `testASavedPresetCarriesNoMasks`, for Point Color.
    func testASavedPresetCarriesNoPointColors() {
        let currentEditState = fullyEditedState() // pointColors is non-empty

        let savedPreset = currentEditState.applyingPreset(onto: .identity)

        XCTAssertEqual(savedPreset.pointColors, [])
    }

    /// `applyingPreset(onto:)` and `comparisonOriginal()` draw the color/
    /// tone-vs-geometry line in exactly the same place — but they are NOT
    /// perfect complements for `redEyePoints`: `comparisonOriginal()`
    /// unconditionally CLEARS points (Compare's "original" side wants zero
    /// retouching), while `applyingPreset(onto:)` unconditionally PRESERVES
    /// the target's own points (a preset must never move another photo's
    /// correction markers). This pins that specific, deliberate asymmetry
    /// down explicitly rather than assuming a full round trip — the same
    /// "don't assume symmetry" discipline this project has needed before
    /// (see PROGRESS.md's Vibrance notes).
    func testApplyingAStatesOwnColorOntoItsOwnComparisonOriginalReproducesEverythingExceptRedEyePointsAndMasksAndPointColors() {
        let state = fullyEditedState()

        let roundTripped = state.applyingPreset(onto: state.comparisonOriginal())

        var expected = state
        expected.redEyePoints = [] // comparisonOriginal() cleared these; applyingPreset never restores them
        expected.masks = [] // same asymmetry as redEyePoints -- see both methods' own doc comments
        expected.pointColors = [] // same asymmetry again -- see both methods' own doc comments
        XCTAssertEqual(roundTripped, expected)
        XCTAssertNotEqual(
            roundTripped.redEyePoints, state.redEyePoints,
            "documents the asymmetry explicitly — not an oversight if this ever fails"
        )
        XCTAssertNotEqual(
            roundTripped.masks, state.masks,
            "documents the same asymmetry for masks — not an oversight if this ever fails"
        )
        XCTAssertNotEqual(
            roundTripped.pointColors, state.pointColors,
            "documents the same asymmetry for point colors — not an oversight if this ever fails"
        )
    }
}
