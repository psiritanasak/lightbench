import XCTest
@testable import PhotoApp

/// Verifies `EditState.requiresRawRedecode(comparedTo:)` — the single
/// source of truth for "does this field change require a full RAW
/// re-decode, not just an `EditPipeline` re-run." `ImageDocumentModel`'s
/// `editState` `didSet` is the only caller; a false negative here would mean
/// a RAW-native field change silently has no visible effect (the exact bug
/// `RawDecoder.materialize`'s "forward hazard" note predicted), and a false
/// positive would mean an unrelated slider edit pays a needless multi-second
/// re-decode. Phase 6 slice 3 added `rawExposureEV`/`shadowBoostScale` to
/// `boostAmount`; slice 4 added `rawWhiteBalanceNeutralPoints`; slice 5
/// added `rawLuminanceNoiseReductionAdjust`/`rawColorNoiseReductionScale`/
/// `rawSharpnessScale`; slice 6 added `rawContrastAdjust`/
/// `rawDetailAdjust`/`rawMoireReductionAdjust`; slice 7 added
/// `rawDecoderVersionPin`. Each field gets its own true case so a
/// missing `||` clause for any one of them can't hide behind another.
final class EditStateRawRedecodeTests: XCTestCase {
    func testTrueWhenBoostAmountDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.boostAmount = 0.2
        b.boostAmount = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawExposureEVDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawExposureEV = -1
        b.rawExposureEV = 1
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenShadowBoostScaleDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.shadowBoostScale = 0.2
        b.shadowBoostScale = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawWhiteBalanceNeutralPointsDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawWhiteBalanceNeutralPoints = [RawNeutralPoint(x: 0.3, y: 0.4)]
        b.rawWhiteBalanceNeutralPoints = [RawNeutralPoint(x: 0.6, y: 0.7)]
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawLuminanceNoiseReductionAdjustDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawLuminanceNoiseReductionAdjust = 0.2
        b.rawLuminanceNoiseReductionAdjust = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawColorNoiseReductionScaleDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawColorNoiseReductionScale = 0.2
        b.rawColorNoiseReductionScale = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawSharpnessScaleDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawSharpnessScale = 0.2
        b.rawSharpnessScale = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawContrastAdjustDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawContrastAdjust = 0.2
        b.rawContrastAdjust = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawDetailAdjustDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawDetailAdjust = 0.2
        b.rawDetailAdjust = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawMoireReductionAdjustDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawMoireReductionAdjust = 0.2
        b.rawMoireReductionAdjust = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testTrueWhenRawDecoderVersionPinDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.rawDecoderVersionPin = "6"
        b.rawDecoderVersionPin = "7"
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testFalseWhenAllRawNativeFieldsAreTheSame() {
        var a = EditState.identity
        var b = EditState.identity
        a.boostAmount = 0.5
        b.boostAmount = 0.5
        a.rawExposureEV = 0.75
        b.rawExposureEV = 0.75
        a.shadowBoostScale = 0.3
        b.shadowBoostScale = 0.3
        a.rawWhiteBalanceNeutralPoints = [RawNeutralPoint(x: 0.1, y: 0.9)]
        b.rawWhiteBalanceNeutralPoints = [RawNeutralPoint(x: 0.1, y: 0.9)]
        a.rawLuminanceNoiseReductionAdjust = 0.4
        b.rawLuminanceNoiseReductionAdjust = 0.4
        a.rawColorNoiseReductionScale = 0.6
        b.rawColorNoiseReductionScale = 0.6
        a.rawSharpnessScale = 0.7
        b.rawSharpnessScale = 0.7
        a.rawContrastAdjust = 0.25
        b.rawContrastAdjust = 0.25
        a.rawDetailAdjust = 1.1
        b.rawDetailAdjust = 1.1
        a.rawMoireReductionAdjust = 0.35
        b.rawMoireReductionAdjust = 0.35
        a.rawDecoderVersionPin = "7"
        b.rawDecoderVersionPin = "7"
        XCTAssertFalse(a.requiresRawRedecode(comparedTo: b))
    }

    func testFalseWhenOnlyAnUnrelatedFieldDiffers() {
        var a = EditState.identity
        let b = EditState.identity
        a.exposureEV = 1.5
        a.contrast = 0.3
        a.blackAndWhite = true
        XCTAssertFalse(a.requiresRawRedecode(comparedTo: b))
    }

    func testFalseWhenOnlyTheToneCurveDiffers() {
        // Deliberately excluded from `requiresRawRedecode`, same as `masks`:
        // the point curve is an `EditPipeline` stage, not a `CIRAWFilter`
        // setting, so including it would fire a multi-second RAW re-decode
        // on every point drag.
        var a = EditState.identity
        let b = EditState.identity
        a.toneCurvePoints = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.7),
            ToneCurvePoint(x: 1, y: 1)
        ]
        XCTAssertFalse(a.requiresRawRedecode(comparedTo: b))
    }

    /// Same exclusion, same reasoning, for the three per-channel curves
    /// (Curves v2 slice 3).
    func testFalseWhenOnlyAPerChannelToneCurveDiffers() {
        var a = EditState.identity
        let b = EditState.identity
        a.toneCurvePointsRed = [ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 1, y: 0.9)]
        a.toneCurvePointsGreen = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        a.toneCurvePointsBlue = [ToneCurvePoint(x: 0, y: 0.05), ToneCurvePoint(x: 1, y: 0.95)]
        XCTAssertFalse(a.requiresRawRedecode(comparedTo: b))
    }

    /// Phase 7 slice 2's regression guard: `masks` is an `EditPipeline`
    /// stage, not a `CIRAWFilter` setting — a `true` here would fire a
    /// multi-second RAW re-decode on every mask drag, the exact silent,
    /// expensive failure mode this whole function exists to prevent.
    func testFalseWhenOnlyMasksDiffers() {
        var a = EditState.identity
        let b = EditState.identity
        a.masks = [Mask(centerX: 0.4, centerY: 0.4, radiusX: 0.2, radiusY: 0.2, exposureEV: 1.0)]
        XCTAssertFalse(a.requiresRawRedecode(comparedTo: b))
    }

    /// Grain is an `EditPipeline` stage (a custom kernel blend), not a
    /// `CIRAWFilter` setting — a `true` here would fire a multi-second RAW
    /// re-decode on every grain slider drag.
    func testFalseWhenOnlyGrainDiffers() {
        var a = EditState.identity
        let b = EditState.identity
        a.grain = 0.5
        XCTAssertFalse(a.requiresRawRedecode(comparedTo: b))
    }

    func testFalseComparedToItself() {
        var a = EditState.identity
        a.boostAmount = 0.6
        a.rawExposureEV = -0.4
        a.shadowBoostScale = 0.9
        XCTAssertFalse(a.requiresRawRedecode(comparedTo: a))
    }
}
