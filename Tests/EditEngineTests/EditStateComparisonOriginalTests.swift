import XCTest
import CoreImage
@testable import PhotoApp

/// Verifies `EditState.comparisonOriginal()` — the Compare feature's
/// "original" side. The two invariants this design rests on: every
/// color/tone field resets to identity (so the "original" really looks
/// unedited), and every geometry field is preserved EXACTLY (so both
/// compared images share one extent and align pixel-for-pixel). Also the
/// regression guard for the red-eye decision (see the method's own doc
/// comment): `redEyePoints` must be cleared, not just the size/strength
/// sliders reset, or red-eye correction would still visibly apply on the
/// "original" side.
final class EditStateComparisonOriginalTests: XCTestCase {
    /// A fully non-identity `EditState`: every color/tone field pushed away
    /// from its default, every geometry field pushed away from its
    /// default, and a real red-eye point placed.
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
        s.transformScale = 1.2
        s.transformAspect = 0.3
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

    func testColorAndToneFieldsAreResetToIdentity() {
        let original = fullyEditedState().comparisonOriginal()
        let identity = EditState.identity
        XCTAssertEqual(original.exposureEV, identity.exposureEV)
        XCTAssertEqual(original.brightness, identity.brightness)
        XCTAssertEqual(original.brilliance, identity.brilliance)
        XCTAssertEqual(original.contrast, identity.contrast)
        XCTAssertEqual(original.curvesHighlights, identity.curvesHighlights)
        XCTAssertEqual(original.curvesShadows, identity.curvesShadows)
        XCTAssertEqual(original.toneCurvePoints, identity.toneCurvePoints)
        XCTAssertEqual(original.toneCurvePointsRed, identity.toneCurvePointsRed)
        XCTAssertEqual(original.toneCurvePointsGreen, identity.toneCurvePointsGreen)
        XCTAssertEqual(original.toneCurvePointsBlue, identity.toneCurvePointsBlue)
        XCTAssertEqual(original.blackPoint, identity.blackPoint)
        XCTAssertEqual(original.levelsBlackPoint, identity.levelsBlackPoint)
        XCTAssertEqual(original.levelsWhitePoint, identity.levelsWhitePoint)
        XCTAssertEqual(original.levelsGamma, identity.levelsGamma)
        XCTAssertEqual(original.whiteBalanceTemperature, identity.whiteBalanceTemperature)
        XCTAssertEqual(original.whiteBalanceTint, identity.whiteBalanceTint)
        XCTAssertEqual(original.hslHue, identity.hslHue)
        XCTAssertEqual(original.vibrance, identity.vibrance)
        XCTAssertEqual(original.hslSaturation, identity.hslSaturation)
        XCTAssertEqual(original.selectiveColorRange, identity.selectiveColorRange)
        XCTAssertEqual(original.redHue, 0); XCTAssertEqual(original.magentaLuminance, 0)
        XCTAssertEqual(original.blackAndWhite, identity.blackAndWhite)
        XCTAssertEqual(original.shadowHue, identity.shadowHue)
        XCTAssertEqual(original.shadowSaturation, identity.shadowSaturation)
        XCTAssertEqual(original.shadowLuminance, identity.shadowLuminance)
        XCTAssertEqual(original.midtoneHue, identity.midtoneHue)
        XCTAssertEqual(original.midtoneSaturation, identity.midtoneSaturation)
        XCTAssertEqual(original.midtoneLuminance, identity.midtoneLuminance)
        XCTAssertEqual(original.highlightHue, identity.highlightHue)
        XCTAssertEqual(original.highlightSaturation, identity.highlightSaturation)
        XCTAssertEqual(original.highlightLuminance, identity.highlightLuminance)
        XCTAssertEqual(original.vignetteStrength, identity.vignetteStrength)
        XCTAssertEqual(original.vignetteRadius, identity.vignetteRadius)
        XCTAssertEqual(original.clarity, identity.clarity)
        XCTAssertEqual(original.sharpness, identity.sharpness)
        XCTAssertEqual(original.noiseReduction, identity.noiseReduction)
        XCTAssertEqual(original.grain, identity.grain)
        XCTAssertEqual(original.redEyeSize, identity.redEyeSize)
        XCTAssertEqual(original.redEyeStrength, identity.redEyeStrength)
    }

    /// The real regression guard: NOT just resetting the sliders, but
    /// actually clearing placed points — see the method's own doc comment
    /// for why leaving them populated would still show red-eye correction.
    func testRedEyePointsAreCleared() {
        let edited = fullyEditedState()
        XCTAssertFalse(edited.redEyePoints.isEmpty, "test fixture should start with points placed")
        XCTAssertTrue(edited.comparisonOriginal().redEyePoints.isEmpty)
    }

    /// Masks are retouching/stylization, same as red-eye points just above
    /// — a non-identity mask is unconditionally active, so leaving it
    /// populated would obviously break this method's "zero retouching"
    /// contract for the "original" side.
    func testMasksAreCleared() {
        let edited = fullyEditedState()
        XCTAssertFalse(edited.masks.isEmpty, "test fixture should start with a mask placed")
        XCTAssertTrue(edited.comparisonOriginal().masks.isEmpty)
    }

    /// Point Color is retouching/stylization, same reasoning as masks
    /// just above.
    func testPointColorsAreCleared() {
        let edited = fullyEditedState()
        XCTAssertFalse(edited.pointColors.isEmpty, "test fixture should start with a point color instance placed")
        XCTAssertTrue(edited.comparisonOriginal().pointColors.isEmpty)
    }

    func testGeometryFieldsAreLeftByteIdenticalToTheInput() {
        let edited = fullyEditedState()
        let original = edited.comparisonOriginal()
        XCTAssertEqual(original.straightenAngle, edited.straightenAngle)
        XCTAssertEqual(original.verticalPerspective, edited.verticalPerspective)
        XCTAssertEqual(original.horizontalPerspective, edited.horizontalPerspective)
        XCTAssertEqual(original.transformScale, edited.transformScale)
        XCTAssertEqual(original.transformAspect, edited.transformAspect)
        XCTAssertEqual(original.flipHorizontal, edited.flipHorizontal)
        XCTAssertEqual(original.flipVertical, edited.flipVertical)
        XCTAssertEqual(original.cropInsetTop, edited.cropInsetTop)
        XCTAssertEqual(original.cropInsetBottom, edited.cropInsetBottom)
        XCTAssertEqual(original.cropInsetLeft, edited.cropInsetLeft)
        XCTAssertEqual(original.cropInsetRight, edited.cropInsetRight)
    }

    /// The invariant the whole single-`fitRect` Compare design rests on:
    /// running `EditPipeline` on both the edited state and its comparison
    /// original must produce the SAME extent, since only geometry (not
    /// color/tone) affects extent.
    func testComparisonOriginalProducesTheSameExtentAsTheEditedState() {
        let edited = fullyEditedState()
        let original = edited.comparisonOriginal()
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let editedExtent = EditPipeline.apply(edited, to: image).extent
        let originalExtent = EditPipeline.apply(original, to: image).extent
        XCTAssertEqual(editedExtent, originalExtent)
    }

    /// Every RAW-native field is preserved like geometry, NOT reset like
    /// every color/tone field — deliberately, because `EditPipeline`
    /// never reads any of them (see each field's own doc comment), so
    /// `comparisonOriginal()` has no way to actually apply a reset here
    /// regardless of what value it sets.
    func testBoostAmountIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().boostAmount, edited.boostAmount)
        XCTAssertNotEqual(edited.boostAmount, EditState.identity.boostAmount, "test fixture should start non-default")
    }

    func testRawExposureEVIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawExposureEV, edited.rawExposureEV)
        XCTAssertNotEqual(edited.rawExposureEV, EditState.identity.rawExposureEV, "test fixture should start non-default")
    }

    func testShadowBoostScaleIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().shadowBoostScale, edited.shadowBoostScale)
        XCTAssertNotEqual(edited.shadowBoostScale, EditState.identity.shadowBoostScale, "test fixture should start non-default")
    }

    func testRawWhiteBalanceNeutralPointsIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawWhiteBalanceNeutralPoints, edited.rawWhiteBalanceNeutralPoints)
        XCTAssertNotEqual(edited.rawWhiteBalanceNeutralPoints, EditState.identity.rawWhiteBalanceNeutralPoints, "test fixture should start non-default")
    }

    func testRawLuminanceNoiseReductionAdjustIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawLuminanceNoiseReductionAdjust, edited.rawLuminanceNoiseReductionAdjust)
        XCTAssertNotEqual(edited.rawLuminanceNoiseReductionAdjust, EditState.identity.rawLuminanceNoiseReductionAdjust, "test fixture should start non-default")
    }

    func testRawColorNoiseReductionScaleIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawColorNoiseReductionScale, edited.rawColorNoiseReductionScale)
        XCTAssertNotEqual(edited.rawColorNoiseReductionScale, EditState.identity.rawColorNoiseReductionScale, "test fixture should start non-default")
    }

    func testRawSharpnessScaleIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawSharpnessScale, edited.rawSharpnessScale)
        XCTAssertNotEqual(edited.rawSharpnessScale, EditState.identity.rawSharpnessScale, "test fixture should start non-default")
    }

    func testRawContrastAdjustIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawContrastAdjust, edited.rawContrastAdjust)
        XCTAssertNotEqual(edited.rawContrastAdjust, EditState.identity.rawContrastAdjust, "test fixture should start non-default")
    }

    func testRawDetailAdjustIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawDetailAdjust, edited.rawDetailAdjust)
        XCTAssertNotEqual(edited.rawDetailAdjust, EditState.identity.rawDetailAdjust, "test fixture should start non-default")
    }

    func testRawMoireReductionAdjustIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawMoireReductionAdjust, edited.rawMoireReductionAdjust)
        XCTAssertNotEqual(edited.rawMoireReductionAdjust, EditState.identity.rawMoireReductionAdjust, "test fixture should start non-default")
    }

    func testRawDecoderVersionPinIsPreservedNotReset() {
        let edited = fullyEditedState()
        XCTAssertEqual(edited.comparisonOriginal().rawDecoderVersionPin, edited.rawDecoderVersionPin)
        XCTAssertNotEqual(edited.rawDecoderVersionPin, EditState.identity.rawDecoderVersionPin, "test fixture should start non-default")
    }
}
