import XCTest
@testable import PhotoApp

/// The Camera Raw -> EditState table: each rule's scale/sign, clamping, curves, crop, present-vs-absent merging, and the mapped/ignored lists.
@MainActor
final class LightroomMappingTests: XCTestCase {
    private func settings(_ scalars: [String: String], curves: [String: [CGPoint]] = [:], structured: Set<String> = []) -> AdobeCameraRawSettings {
        AdobeCameraRawSettings(scalars: scalars, curves: curves, structuredNames: structured)
    }

    private func map(_ scalars: [String: String], curves: [String: [CGPoint]] = [:], structured: Set<String> = [], includeCrop: Bool = false) -> LightroomMapping.Result {
        LightroomMapping.editState(from: settings(scalars, curves: curves, structured: structured), includeCrop: includeCrop)
    }

    private func plan(_ scalars: [String: String], curves: [String: [CGPoint]] = [:], includeCrop: Bool = false, cropAllowed: Bool = true) -> LightroomMapping.Plan {
        LightroomMapping.plan(from: settings(scalars, curves: curves), includeCrop: includeCrop, cropAllowed: cropAllowed)
    }

    // MARK: - Scalars

    func testEmptySettingsGiveIdentityAndNothingMapped() {
        let r = map([:])
        XCTAssertEqual(r.state, EditState.identity)
        XCTAssertTrue(r.mapped.isEmpty)
        XCTAssertTrue(r.ignored.isEmpty)
    }

    func testExposureIsOneStopPerEV() {
        XCTAssertEqual(map(["Exposure2012": "+0.65"]).state.exposureEV, 0.65, accuracy: 1e-12)
        XCTAssertEqual(map(["Exposure2012": "-2.5"]).state.exposureEV, -2.5, accuracy: 1e-12)
    }

    func testHundredScaleSlidersMapToUnitRange() {
        let r = map(["Highlights2012": "-40", "Shadows2012": "+60", "Whites2012": "+21", "Blacks2012": "-15",
                     "Texture": "+30", "Clarity2012": "-20", "Dehaze": "+10", "Vibrance": "+10", "Saturation": "-50"])
        XCTAssertEqual(r.state.curvesHighlights, -0.40, accuracy: 1e-12)
        XCTAssertEqual(r.state.curvesShadows, 0.60, accuracy: 1e-12)
        XCTAssertEqual(r.state.whites, 0.21, accuracy: 1e-12)
        XCTAssertEqual(r.state.blackPoint, -0.15, accuracy: 1e-12)
        XCTAssertEqual(r.state.texture, 0.30, accuracy: 1e-12)
        XCTAssertEqual(r.state.clarity, -0.20, accuracy: 1e-12)
        XCTAssertEqual(r.state.dehaze, 0.10, accuracy: 1e-12)
        XCTAssertEqual(r.state.vibrance, 0.10, accuracy: 1e-12)
        XCTAssertEqual(r.state.hslSaturation, -0.50, accuracy: 1e-12)
        XCTAssertEqual(r.mapped.count, 9)
    }

    func testContrastIsNotImportedAndIsReportedWithItsReason() {
        let r = map(["Contrast2012": "+28", "Exposure2012": "+1"])
        XCTAssertEqual(r.state.contrast, 0)
        XCTAssertEqual(r.mapped, ["Exposure2012"])
        XCTAssertEqual(r.ignored, ["Contrast2012 (not calibrated: made the match worse on the test photo)"])
        XCTAssertTrue(map(["Contrast2012": "0"]).ignored.isEmpty, "a zero contrast says nothing worth reporting")
        // And merging never touches the user's own contrast.
        var target = EditState.identity
        target.contrast = 0.4
        XCTAssertEqual(LightroomMapping.merge(plan(["Contrast2012": "+28"]), onto: target).contrast, 0.4)
    }

    func testValuesAreClampedToTheFieldRanges() {
        let r = map(["Exposure2012": "+99", "Highlights2012": "+500", "Shadows2012": "-500", "LuminanceSmoothing": "250",
                     "GrainAmount": "-30", "PostCropVignetteAmount": "-1000"])
        XCTAssertEqual(r.state.exposureEV, 5)
        XCTAssertEqual(r.state.curvesHighlights, 1)
        XCTAssertEqual(r.state.curvesShadows, -1)
        XCTAssertEqual(r.state.noiseReduction, 1)
        XCTAssertEqual(r.state.grain, 0)
        XCTAssertEqual(r.state.vignetteStrength, 1)
    }

    func testVignetteSignIsFlippedBecauseCameraRawNegativeDarkens() {
        XCTAssertEqual(map(["PostCropVignetteAmount": "-40"]).state.vignetteStrength, 0.4, accuracy: 1e-12)
        XCTAssertEqual(map(["PostCropVignetteAmount": "+40"]).state.vignetteStrength, -0.4, accuracy: 1e-12)
        XCTAssertEqual(map(["PostCropVignetteAmount": "0"]).state.vignetteStrength.sign, .plus, "no negative zero")
    }

    func testLuminanceSmoothingAndGrainUseTheZeroToOneRange() {
        let r = map(["LuminanceSmoothing": "40", "GrainAmount": "25"])
        XCTAssertEqual(r.state.noiseReduction, 0.40, accuracy: 1e-12)
        XCTAssertEqual(r.state.grain, 0.25, accuracy: 1e-12)
    }

    func testAllEightBandsMapHueSaturationLuminance() {
        let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        var scalars: [String: String] = [:]
        for (i, band) in bands.enumerated() {
            scalars["HueAdjustment" + band] = "\(i + 1)0"
            scalars["SaturationAdjustment" + band] = "-\(i + 1)0"
            scalars["LuminanceAdjustment" + band] = "\(i + 1)"
        }
        let s = map(scalars).state
        XCTAssertEqual([s.redHue, s.orangeHue, s.yellowHue, s.greenHue, s.aquaHue, s.blueHue, s.purpleHue, s.magentaHue],
                       [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
        XCTAssertEqual([s.redSaturation, s.orangeSaturation, s.yellowSaturation, s.greenSaturation, s.aquaSaturation,
                        s.blueSaturation, s.purpleSaturation, s.magentaSaturation], [-0.1, -0.2, -0.3, -0.4, -0.5, -0.6, -0.7, -0.8])
        XCTAssertEqual(s.magentaLuminance, 0.08, accuracy: 1e-12)
        XCTAssertEqual(map(scalars).mapped.count, 24)
    }

    func testMalformedNumbersAreTreatedAsAbsent() {
        let r = map(["Exposure2012": "nan", "Highlights2012": "abc", "Dehaze": ""])
        XCTAssertEqual(r.state, EditState.identity)
        XCTAssertTrue(r.mapped.isEmpty)
        XCTAssertTrue(plan(["Exposure2012": "nan"]).presentRules.isEmpty)
    }

    func testGrayscaleFlag() {
        XCTAssertTrue(map(["ConvertToGrayscale": "True"]).state.blackAndWhite)
        XCTAssertEqual(map(["ConvertToGrayscale": "True"]).mapped, ["ConvertToGrayscale"])
        XCTAssertFalse(map(["ConvertToGrayscale": "False"]).state.blackAndWhite)
    }

    func testZeroValuesAreNotCountedAsMapped() {
        let r = map(["Exposure2012": "0.00", "Highlights2012": "0", "Vibrance": "+10"])
        XCTAssertEqual(r.mapped, ["Vibrance"])
    }

    func testNominalAppliedListsEverythingButExposure() {
        let p = plan(["Exposure2012": "+1", "Vibrance": "+10", "Texture": "+5", "Dehaze": "0"])
        XCTAssertEqual(p.mapped, ["Exposure2012", "Texture", "Vibrance"])
        XCTAssertEqual(p.appliedNominal, ["Texture", "Vibrance"])
    }

    // MARK: - Curves

    func testCurveIsScaledTo01AndWrittenToItsChannel() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 64, y: 51), CGPoint(x: 255, y: 255)]
        let r = map([:], curves: ["ToneCurvePV2012": pts, "ToneCurvePV2012Red": [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 153), CGPoint(x: 255, y: 255)]])
        XCTAssertEqual(r.state.toneCurvePoints.map(\.x), [0, 64 / 255.0, 1])
        XCTAssertEqual(r.state.toneCurvePoints[1].y, 51 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(r.state.toneCurvePointsRed.count, 3)
        XCTAssertTrue(r.state.toneCurvePointsGreen.isEmpty)
        XCTAssertEqual(r.mapped, ["ToneCurvePV2012", "ToneCurvePV2012Red"])
    }

    func testIdentityCurveMapsToNoCurve() {
        let r = map([:], curves: ["ToneCurvePV2012": [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]])
        XCTAssertTrue(r.state.toneCurvePoints.isEmpty)
        XCTAssertTrue(r.mapped.isEmpty)
    }

    func testCurveIsCappedAtEightPointsKeepingEndpoints() {
        let pts = (0...15).map { CGPoint(x: Double($0) * 17, y: min(255, Double($0) * 17 + ($0 == 7 ? 20 : 0))) }
        let out = LightroomMapping.curvePoints(from: pts)
        XCTAssertEqual(out.count, MonotoneToneCurve.maximumPointCount)
        XCTAssertEqual(out.first?.x, 0)
        XCTAssertEqual(out.last?.x, 1)
        XCTAssertNotNil(MonotoneToneCurve(points: out), "the capped curve must be a valid render input")
        XCTAssertTrue(out.contains { abs($0.x - 119 / 255.0) < 1e-9 }, "the one point that bends the curve survives the thinning")
    }

    func testCurveIsSortedClampedAndDeduplicated() {
        let out = LightroomMapping.curvePoints(from: [CGPoint(x: 255, y: 300), CGPoint(x: 100, y: 130), CGPoint(x: 100.1, y: 140), CGPoint(x: -5, y: -9)])
        XCTAssertEqual(out.map(\.x), [0, 100 / 255.0, 1])
        XCTAssertEqual(out.last?.y, 1)
        XCTAssertEqual(out.first?.y, 0)
        XCTAssertNotNil(MonotoneToneCurve(points: out))
    }

    func testSinglePointCurveIsDropped() {
        XCTAssertTrue(LightroomMapping.curvePoints(from: [CGPoint(x: 10, y: 20)]).isEmpty)
        XCTAssertTrue(LightroomMapping.curvePoints(from: []).isEmpty)
    }

    // MARK: - Crop

    func testCropIsOnlyImportedWhenAskedAndWhenHasCrop() {
        let crop = ["HasCrop": "True", "CropLeft": "0.1", "CropTop": "0.2", "CropRight": "0.9", "CropBottom": "0.7"]
        let off = map(crop, includeCrop: false)
        XCTAssertEqual(off.state.cropInsetLeft, 0)
        XCTAssertEqual(off.state.cropInsetBottom, 0)
        XCTAssertTrue(off.ignored.contains("Crop (not included)"))
        XCTAssertFalse(off.mapped.contains("Crop"))

        let on = map(crop, includeCrop: true)
        XCTAssertEqual(on.state.cropInsetLeft, 0.1, accuracy: 1e-12)
        XCTAssertEqual(on.state.cropInsetTop, 0.2, accuracy: 1e-12)
        XCTAssertEqual(on.state.cropInsetRight, 0.1, accuracy: 1e-12)
        XCTAssertEqual(on.state.cropInsetBottom, 0.3, accuracy: 1e-12)
        XCTAssertTrue(on.mapped.contains("Crop"))
        XCTAssertFalse(on.ignored.contains("Crop (not included)"))

        let noFlag = map(["HasCrop": "False", "CropLeft": "0.1", "CropRight": "0.9"], includeCrop: true)
        XCTAssertEqual(noFlag.state.cropInsetLeft, 0)
        XCTAssertFalse(noFlag.mapped.contains("Crop"))
    }

    func testAnInsetBeyondTheLimitRefusesTheWholeCropInsteadOfClamping() {
        let p = plan(["HasCrop": "True", "CropLeft": "0.9", "CropTop": "0.1", "CropRight": "1", "CropBottom": "1", "Vibrance": "+10"], includeCrop: true)
        XCTAssertNotNil(p.cropRefusal)
        XCTAssertTrue(p.cropRefusal?.contains("45 %") == true)
        XCTAssertFalse(p.includesCrop)
        XCTAssertEqual(p.state.cropInsetLeft, 0, "no silent clamp to a different region")
        XCTAssertEqual(p.state.cropInsetTop, 0)
        XCTAssertEqual(p.mapped, ["Vibrance"], "the rest still imports")
        XCTAssertTrue(p.ignored.contains("Crop (refused)"))
        // Exactly at the limit is fine.
        XCTAssertTrue(plan(["HasCrop": "True", "CropLeft": "0.45", "CropRight": "1", "CropBottom": "1"], includeCrop: true).includesCrop)
        // Too-negative edge values are refused too.
        XCTAssertNotNil(plan(["HasCrop": "True", "CropLeft": "-0.5"], includeCrop: true).cropRefusal)
    }

    func testCropIsRefusedForAPhotoThatIsNotUpright() {
        let crop = ["HasCrop": "True", "CropLeft": "0.1", "CropRight": "0.9", "Vibrance": "+10"]
        let p = plan(crop, includeCrop: true, cropAllowed: false)
        XCTAssertNotNil(p.cropRefusal)
        XCTAssertFalse(p.includesCrop)
        XCTAssertEqual(p.state.cropInsetLeft, 0)
        XCTAssertEqual(p.mapped, ["Vibrance"])
        XCTAssertNil(plan(crop, includeCrop: true, cropAllowed: true).cropRefusal)
        XCTAssertNil(plan(crop, includeCrop: false, cropAllowed: false).cropRefusal, "nothing was asked, nothing is refused")
    }

    func testFullFrameCropIsNotACrop() {
        let r = map(["HasCrop": "True", "CropLeft": "0", "CropTop": "0", "CropRight": "1", "CropBottom": "1"], includeCrop: true)
        XCTAssertFalse(r.mapped.contains("Crop"))
    }

    func testCropAngleIsNeverImportedButIsReported() {
        let r = map(["HasCrop": "True", "CropAngle": "2.5"], includeCrop: true)
        XCTAssertEqual(r.state.straightenAngle, 0)
        XCTAssertTrue(r.ignored.contains("CropAngle"))
    }

    // MARK: - Ignored list

    func testUnsupportedSettingsWithValuesAreListedAndDefaultsAreNot() {
        let r = map(["Temperature": "2400", "Tint": "+6", "WhiteBalance": "Custom", "Sharpness": "25", "ColorNoiseReduction": "25",
                     "ColorGradeMidtoneHue": "120", "LensManualDistortionAmount": "0", "ParametricShadowSplit": "25",
                     "SplitToningShadowSaturation": "30", "Version": "8.5", "ProcessVersion": "6.7", "CameraProfile": "Adobe Standard",
                     "PerspectiveScale": "100", "Exposure2012": "+1"])
        XCTAssertEqual(r.ignored, ["ColorGradeMidtoneHue", "SplitToningShadowSaturation", "Temperature", "Tint"])
        XCTAssertEqual(r.mapped, ["Exposure2012"])
    }

    func testWhiteBalanceIsNotReportedForAsShotFiles() {
        XCTAssertTrue(map(["WhiteBalance": "As Shot", "Temperature": "5200", "Tint": "+3"]).ignored.isEmpty)
    }

    func testSharpnessAboveTheFactoryDefaultIsReported() {
        XCTAssertEqual(map(["Sharpness": "60"]).ignored, ["Sharpness"])
    }

    func testMasksSpotsAndLooksAreNamedInIgnored() {
        let r = map(["Exposure2012": "+1"], structured: ["MaskGroupBasedCorrections", "GradientBasedCorrections", "CircularGradientBasedCorrections",
                                                         "PaintBasedCorrections", "RetouchAreas", "Look"])
        XCTAssertEqual(r.ignored, ["CircularGradientBasedCorrections", "GradientBasedCorrections", "Look", "MaskGroupBasedCorrections",
                                   "PaintBasedCorrections", "RetouchAreas"])
    }

    func testLegacyCurvesAreReportedOnlyWhenNoPV2012CurveSupersedesThem() {
        let bent = [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 150), CGPoint(x: 255, y: 255)]
        XCTAssertEqual(map([:], curves: ["ToneCurve": bent]).ignored, ["ToneCurve"])
        let straight = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
        XCTAssertTrue(map([:], curves: ["ToneCurve": straight]).ignored.isEmpty)
        XCTAssertTrue(map([:], curves: ["ToneCurve": bent, "ToneCurvePV2012": straight]).ignored.isEmpty, "inactive under a PV2012 file")
    }

    func testStructFieldNamesAreNotSilencedAsBookkeeping() {
        // Names that only ever appear INSIDE a Look struct are ordinary names at top level: a non-zero one is reported.
        XCTAssertEqual(map(["Amount": "5"]).ignored, ["Amount"])
    }

    // MARK: - Older process versions

    func testALegacyProcessFileIsRefused() {
        let pv2010 = plan(["ProcessVersion": "3.7", "Exposure": "+0.5", "Brightness": "+40", "Contrast": "25", "Vibrance": "+10"])
        XCTAssertEqual(pv2010.refusal, "This file uses an older Camera Raw process version (3.7); nothing was imported.")
        var target = EditState.identity
        target.vibrance = 0.3
        XCTAssertEqual(LightroomMapping.merge(pv2010, onto: target), target, "a refused plan changes nothing")
        // Legacy keys without a version are enough.
        XCTAssertNotNil(plan(["Exposure": "+0.5"]).refusal)
    }

    func testAnOldProcessVersionAloneRefusesAndTheBoundaryIsNot() {
        XCTAssertNotNil(plan(["ProcessVersion": "3.7", "Vibrance": "+10"]).refusal, "the version string alone is enough")
        // Camera Raw numbering: 5.0 = PV2003, 5.7 = PV2010, 6.7 = PV2012.
        XCTAssertNotNil(plan(["ProcessVersion": "5.0", "Vibrance": "+10"]).refusal)
        XCTAssertNotNil(plan(["ProcessVersion": "5.7", "Vibrance": "+10"]).refusal, "5.7 is PV2010")
        XCTAssertNotNil(plan(["ProcessVersion": "6.6", "Vibrance": "+10"]).refusal)
        XCTAssertNil(plan(["ProcessVersion": "6.7", "Vibrance": "+10"]).refusal, "6.7 is PV2012")
        XCTAssertNil(plan(["ProcessVersion": "11.0", "Vibrance": "+10"]).refusal, "newer versions keep the 2012 names")
    }

    func testAPV2010FileWithAStray2012KeyIsStillRefusedAndImportsNothing() {
        let p = plan(["ProcessVersion": "5.7", "Exposure2012": "0", "Shadows2012": "0", "Vibrance": "+10"])
        XCTAssertNotNil(p.refusal)
        var target = EditState.identity
        target.exposureEV = 1
        target.curvesShadows = 0.4
        XCTAssertEqual(LightroomMapping.merge(p, onto: target), target, "no zeros are written over the user's sliders")
        XCTAssertTrue(LightroomMapping.changes(of: p, onto: target).isEmpty)
    }

    func testWithNoVersionTheKeysDecide() {
        XCTAssertNotNil(plan(["Exposure": "+0.5"]).refusal, "no version + legacy keys")
        XCTAssertNil(plan(["Exposure2012": "+0.5"]).refusal, "no version + 2012 keys")
        XCTAssertNil(plan(["Exposure2012": "+0.5", "Exposure": "0.5"]).refusal, "2012 keys win when there is no version")
        XCTAssertNil(plan(["ProcessVersion": "garbage", "Exposure2012": "+0.5"]).refusal, "an unparseable version counts as none")
    }

    func testMergeOfARefusedPlanChangesNothingEvenIfItCarriesValues() {
        var p = LightroomMapping.Plan()
        p.refusal = "refused"
        p.presentRules = ["Vibrance"]
        p.state.vibrance = 0.5
        var target = EditState.identity
        target.vibrance = 0.1
        XCTAssertEqual(LightroomMapping.merge(p, onto: target), target)
    }

    func testAFileWithA2012KeyOrOnlyUnrelatedSlidersIsNotRefused() {
        XCTAssertNil(plan(["ProcessVersion": "6.7", "Exposure2012": "+0.5"]).refusal)
        XCTAssertNil(plan(["ProcessVersion": "6.7", "Vibrance": "+10"]).refusal, "a preset with no tone keys is fine")
        XCTAssertNil(plan(["Vibrance": "+10"]).refusal)
    }

    // MARK: - Merging onto a photo (present vs absent)

    private func busyTarget() -> EditState {
        var target = EditState.identity
        target.straightenAngle = 3
        target.cropInsetLeft = 0.2
        target.flipHorizontal = true
        target.rawExposureEV = 0.5
        target.rawDecoderVersionPin = "7"
        target.whiteBalanceTemperature = 4800
        target.lookID = "builtin:x"
        target.levelsGamma = 1.3
        target.redEyePoints = [RedEyePoint(x: 0.5, y: 0.5)]
        target.masks = [Mask()]
        target.exposureEV = -1
        target.contrast = 0.9
        target.texture = 0.35
        target.blackAndWhite = true
        target.toneCurvePoints = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        target.toneCurvePointsRed = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.4), ToneCurvePoint(x: 1, y: 1)]
        return target
    }

    func testMergeReplacesWhatTheFileCarriesAndKeepsEverythingElse() {
        let target = busyTarget()
        let p = plan(["Exposure2012": "+1", "HasCrop": "True", "CropLeft": "0.05", "CropRight": "0.95"])
        let merged = LightroomMapping.merge(p, onto: target)
        XCTAssertEqual(merged.exposureEV, 1)
        XCTAssertEqual(merged.straightenAngle, 3)
        XCTAssertEqual(merged.cropInsetLeft, 0.2, "crop untouched unless asked")
        XCTAssertTrue(merged.flipHorizontal)
        XCTAssertEqual(merged.rawExposureEV, 0.5)
        XCTAssertEqual(merged.rawDecoderVersionPin, "7")
        XCTAssertEqual(merged.whiteBalanceTemperature, 4800, "unmapped white balance is not reset")
        XCTAssertEqual(merged.lookID, "builtin:x")
        XCTAssertEqual(merged.levelsGamma, 1.3)
        XCTAssertEqual(merged.redEyePoints, target.redEyePoints)
        XCTAssertEqual(merged.masks, target.masks)
    }

    func testAPresentZeroReplacesTheUsersValue() {
        let merged = LightroomMapping.merge(plan(["Exposure2012": "0.00", "Texture": "0"]), onto: busyTarget())
        XCTAssertEqual(merged.exposureEV, 0, "preset semantics: a value the file states, even zero, replaces")
        XCTAssertEqual(merged.texture, 0)
    }

    func testAnAbsentKeyNeverErasesTheUsersValue() {
        let target = busyTarget()
        let merged = LightroomMapping.merge(plan([:]), onto: target)
        XCTAssertEqual(merged, target, "an empty file changes nothing")
    }

    func testAPartialPresetFileLeavesTheRestAlone() {
        let target = busyTarget()
        let p = plan(["Vibrance": "+20", "HueAdjustmentRed": "-10", "SaturationAdjustmentBlue": "+15"])
        let merged = LightroomMapping.merge(p, onto: target)
        XCTAssertEqual(merged.vibrance, 0.2, accuracy: 1e-12)
        XCTAssertEqual(merged.redHue, -0.1, accuracy: 1e-12)
        XCTAssertEqual(merged.blueSaturation, 0.15, accuracy: 1e-12)
        XCTAssertEqual(merged.exposureEV, -1)
        XCTAssertEqual(merged.contrast, 0.9)
        XCTAssertEqual(merged.toneCurvePoints, target.toneCurvePoints)
        XCTAssertEqual(merged.toneCurvePointsRed, target.toneCurvePointsRed)
        XCTAssertTrue(merged.blackAndWhite, "an absent ConvertToGrayscale leaves Black & White alone")
    }

    func testAnOldFileWithoutTextureKeepsTheUsersTexture() {
        let merged = LightroomMapping.merge(plan(["ProcessVersion": "6.7", "Exposure2012": "+0.5", "Clarity2012": "+10"]), onto: busyTarget())
        XCTAssertEqual(merged.texture, 0.35)
        XCTAssertEqual(merged.clarity, 0.10, accuracy: 1e-12)
    }

    func testCurvesAndGrayscaleReplaceOnlyWhenPresent() {
        let target = busyTarget()
        let straight = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
        let reset = LightroomMapping.merge(plan(["ConvertToGrayscale": "False"], curves: ["ToneCurvePV2012": straight]), onto: target)
        XCTAssertFalse(reset.blackAndWhite, "a present False replaces")
        XCTAssertTrue(reset.toneCurvePoints.isEmpty, "a present straight curve replaces")
        XCTAssertEqual(reset.toneCurvePointsRed, target.toneCurvePointsRed, "the Red curve is absent: untouched")
        let bent = [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 150), CGPoint(x: 255, y: 255)]
        let set = LightroomMapping.merge(plan([:], curves: ["ToneCurvePV2012Green": bent]), onto: target)
        XCTAssertEqual(set.toneCurvePointsGreen.count, 3)
        XCTAssertEqual(set.toneCurvePoints, target.toneCurvePoints)
    }

    func testMergeTakesTheCropOnlyWhenIncludedAndTheEditHasNoGeometry() {
        let crop = ["HasCrop": "True", "CropLeft": "0.05", "CropRight": "0.95"]
        var clean = EditState.identity
        clean.contrast = 0.2
        let ok = LightroomMapping.plan(from: settings(crop), includeCrop: true, target: clean)
        XCTAssertNil(ok.cropRefusal)
        let merged = LightroomMapping.merge(ok, onto: clean)
        XCTAssertEqual(merged.cropInsetLeft, 0.05, accuracy: 1e-12)
        XCTAssertEqual(merged.cropInsetRight, 0.05, accuracy: 1e-12)

        // busyTarget() is flipped and straightened: the insets would land on other edges, so the crop is refused and the rest imported.
        let refused = LightroomMapping.plan(from: settings(crop.merging(["Vibrance": "+10"]) { a, _ in a }), includeCrop: true, target: busyTarget())
        XCTAssertNotNil(refused.cropRefusal)
        XCTAssertTrue(refused.cropRefusal?.contains("flip, straighten, perspective or scale") == true)
        XCTAssertFalse(refused.includesCrop)
        let after = LightroomMapping.merge(refused, onto: busyTarget())
        XCTAssertEqual(after.cropInsetLeft, 0.2, "the target's own crop is untouched")
        XCTAssertEqual(after.straightenAngle, 3)
        XCTAssertEqual(after.vibrance, 0.1, accuracy: 1e-12, "the rest still imports")
    }

    func testEachGeometryEditRefusesTheCrop() {
        let crop = settings(["HasCrop": "True", "CropLeft": "0.05"])
        var cases: [(String, (inout EditState) -> Void)] = [
            ("flipH", { $0.flipHorizontal = true }), ("flipV", { $0.flipVertical = true }), ("straighten", { $0.straightenAngle = 1 }),
            ("vertical", { $0.verticalPerspective = 0.1 }), ("horizontal", { $0.horizontalPerspective = -0.1 }),
            ("scale", { $0.transformScale = 1.1 }), ("aspect", { $0.transformAspect = 0.2 })
        ]
        cases.append(("none-is-fine", { _ in }))
        for (name, edit) in cases {
            var target = EditState.identity
            edit(&target)
            let refused = LightroomMapping.plan(from: crop, includeCrop: true, target: target).cropRefusal != nil
            XCTAssertEqual(refused, name != "none-is-fine", name)
        }
    }

    func testAPacketOrientationThatDiffersFromThePhotosRefusesTheCrop() {
        let crop = ["HasCrop": "True", "CropLeft": "0.05"]
        let rotatedPacket = AdobeCameraRawSettings(scalars: crop, tiffOrientation: 8)
        let mismatch = LightroomMapping.plan(from: rotatedPacket, includeCrop: true, photoOrientation: 1)
        XCTAssertNotNil(mismatch.cropRefusal)
        XCTAssertTrue(mismatch.cropRefusal?.contains("orientation") == true)
        XCTAssertNil(LightroomMapping.plan(from: rotatedPacket, includeCrop: true, photoOrientation: 8).cropRefusal)
        XCTAssertNil(LightroomMapping.plan(from: AdobeCameraRawSettings(scalars: crop), includeCrop: true, photoOrientation: 1).cropRefusal,
                     "a packet without tiff:Orientation says nothing")
        XCTAssertNil(LightroomMapping.plan(from: rotatedPacket, includeCrop: true).cropRefusal, "no photo orientation to compare")
    }

    func testContrastInTheFileNeverChangesContrastThroughMerge() {
        var target = EditState.identity
        target.contrast = 0.4
        for value in ["+50", "-30", "0"] {
            let merged = LightroomMapping.merge(plan(["Contrast2012": value, "Exposure2012": "+1"]), onto: target)
            XCTAssertEqual(merged.contrast, 0.4, "Contrast2012 \(value)")
            XCTAssertEqual(merged.exposureEV, 1)
        }
        XCTAssertFalse(LightroomMapping.changes(of: plan(["Contrast2012": "+50"]), onto: target).setNames.contains("Contrast2012"))
    }

    func testImportedCurvesAreListedAsApproximate() {
        let bent = [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 150), CGPoint(x: 255, y: 255)]
        let p = plan(["Exposure2012": "+1"], curves: ["ToneCurvePV2012": bent])
        XCTAssertEqual(p.appliedNominal, ["ToneCurvePV2012"])
    }

    // MARK: - What a full Lightroom file changes

    /// Roughly what Lightroom writes: every slider listed (nearly all 0), four straight PV2012 curves, ConvertToGrayscale=False.
    private func fullLightroomFile() -> AdobeCameraRawSettings {
        var scalars: [String: String] = [
            "Version": "8.5", "ProcessVersion": "6.7", "WhiteBalance": "Custom", "Temperature": "2400", "Tint": "+6", "Sharpness": "25",
            "ColorNoiseReduction": "25", "ConvertToGrayscale": "False", "HasSettings": "True", "HasCrop": "False", "CameraProfile": "Adobe Standard",
            "Exposure2012": "+0.65", "Contrast2012": "+28", "Whites2012": "+21", "Vibrance": "+10"
        ]
        for rule in LightroomMapping.rules where scalars[rule.key] == nil { scalars[rule.key] = "0" }
        scalars["Exposure2012"] = "+0.65"
        let straight = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
        let curves = ["ToneCurvePV2012": straight, "ToneCurvePV2012Red": straight, "ToneCurvePV2012Green": straight, "ToneCurvePV2012Blue": straight]
        return AdobeCameraRawSettings(scalars: scalars, curves: curves)
    }

    func testAFullLightroomFileResetsEverythingItListsAndSaysSo() {
        var target = EditState.identity
        target.exposureEV = -1
        target.contrast = 0.9
        target.texture = 0.3
        target.dehaze = 0.2
        target.redHue = 0.1
        target.blackAndWhite = true
        target.toneCurvePoints = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        target.whiteBalanceTemperature = 4800
        let p = LightroomMapping.plan(from: fullLightroomFile())
        XCTAssertNil(p.refusal)
        XCTAssertEqual(p.presentRules.count, LightroomMapping.rules.count, "every rule key is carried, mostly at 0")
        XCTAssertEqual(p.presentCurves.count, 4)

        let changes = LightroomMapping.changes(of: p, onto: target)
        XCTAssertEqual(changes.setNames, ["Exposure2012", "Vibrance", "Whites2012"])
        XCTAssertEqual(changes.resetSliders, ["Dehaze", "HueAdjustmentRed", "Texture"])
        XCTAssertEqual(changes.resetCurves, ["ToneCurvePV2012"])
        XCTAssertTrue(changes.resetBlackAndWhite)

        let merged = LightroomMapping.merge(p, onto: target)
        XCTAssertEqual(merged.exposureEV, 0.65, accuracy: 1e-12)
        XCTAssertEqual(merged.texture, 0)
        XCTAssertEqual(merged.dehaze, 0)
        XCTAssertEqual(merged.redHue, 0)
        XCTAssertTrue(merged.toneCurvePoints.isEmpty)
        XCTAssertFalse(merged.blackAndWhite)
        XCTAssertEqual(merged.contrast, 0.9, "Contrast is not imported, so it is not touched")
        XCTAssertEqual(merged.whiteBalanceTemperature, 4800)

        let text = LightroomImportModel.summary(plan: p, changes: changes, applied: true)
        XCTAssertTrue(text.hasPrefix("Set 3 settings; also reset 3 sliders to 0, the point curve and Black & White. Ignored "), text)
        XCTAssertTrue(LightroomImportModel.replaceNote.contains("including zeros"))
    }

    func testAnAlreadyMatchingFileChangesNothing() {
        let p = LightroomMapping.plan(from: fullLightroomFile())
        let once = LightroomMapping.merge(p, onto: .identity)
        XCTAssertTrue(LightroomMapping.changes(of: p, onto: once).isEmpty)
    }

    func testARotatedCropIsRefusedAndStillReported() {
        let crop = ["HasCrop": "True", "CropLeft": "0.1", "CropRight": "0.9", "CropAngle": "3.5", "Vibrance": "+10"]
        let p = plan(crop, includeCrop: true)
        XCTAssertNotNil(p.cropRefusal)
        XCTAssertTrue(p.cropRefusal?.contains("rotated") == true)
        XCTAssertFalse(p.includesCrop)
        XCTAssertEqual(p.state.cropInsetLeft, 0)
        XCTAssertEqual(p.mapped, ["Vibrance"])
        XCTAssertTrue(p.ignored.contains("CropAngle"))
        XCTAssertNil(plan(["HasCrop": "True", "CropLeft": "0.1", "CropAngle": "0"], includeCrop: true).cropRefusal, "a zero angle is no rotation")
    }

    func testAFullFrameCropClearsAnExistingCropAndSaysSo() {
        var target = EditState.identity
        target.cropInsetLeft = 0.2
        let p = plan(["HasCrop": "True", "CropLeft": "0", "CropTop": "0", "CropRight": "1", "CropBottom": "1"], includeCrop: true)
        XCTAssertTrue(p.includesCrop)
        let changes = LightroomMapping.changes(of: p, onto: target)
        XCTAssertTrue(changes.clearedCrop)
        XCTAssertFalse(changes.setNames.contains("Crop"))
        XCTAssertFalse(changes.isEmpty)
        XCTAssertEqual(LightroomMapping.merge(p, onto: target).cropInsetLeft, 0)
        XCTAssertTrue(LightroomMapping.changes(of: p, onto: .identity).isEmpty, "nothing to clear")
        // A real crop is still "set".
        let real = plan(["HasCrop": "True", "CropLeft": "0.1"], includeCrop: true)
        XCTAssertTrue(LightroomMapping.changes(of: real, onto: target).setNames.contains("Crop"))
        XCTAssertFalse(LightroomMapping.changes(of: real, onto: target).clearedCrop)
    }
}
