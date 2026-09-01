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
        s.vignetteStrength = 0.5
        s.vignetteRadius = 0.7
        s.definition = 0.4
        s.sharpness = 0.6
        s.noiseReduction = 0.3
        // red-eye
        s.redEyeSize = 0.8
        s.redEyeStrength = 0.9
        s.redEyePoints = [RedEyePoint(x: 0.3, y: 0.4), RedEyePoint(x: 0.6, y: 0.5)]
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
        XCTAssertEqual(result.vignetteStrength, preset.vignetteStrength)
        XCTAssertEqual(result.vignetteRadius, preset.vignetteRadius)
        XCTAssertEqual(result.definition, preset.definition)
        XCTAssertEqual(result.sharpness, preset.sharpness)
        XCTAssertEqual(result.noiseReduction, preset.noiseReduction)
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
    func testApplyingAStatesOwnColorOntoItsOwnComparisonOriginalReproducesEverythingExceptRedEyePoints() {
        let state = fullyEditedState()

        let roundTripped = state.applyingPreset(onto: state.comparisonOriginal())

        var expected = state
        expected.redEyePoints = [] // comparisonOriginal() cleared these; applyingPreset never restores them
        XCTAssertEqual(roundTripped, expected)
        XCTAssertNotEqual(
            roundTripped.redEyePoints, state.redEyePoints,
            "documents the asymmetry explicitly — not an oversight if this ever fails"
        )
    }
}
