import XCTest
@testable import PhotoApp

/// Verifies `EditState`'s custom, schema-tolerant `init(from:)` — extracted
/// from `EditPipelineTests.swift` (already 2500+ lines, matching this
/// project's precedent of splitting out a growing, distinct concern — see
/// `CropAspectMathTests`/`RedEyeHitTestTests`). The existing
/// `testEditStateCodableRoundTrip` (full round-trip of a fully-populated
/// struct) stays in `EditPipelineTests.swift`, untouched — these tests
/// specifically exercise the NEW decoder's tolerance for missing/extra
/// keys, the actual regression this file exists to guard against: sidecar
/// files written today must still decode once a future session adds one
/// more `EditState` field, rather than throwing `keyNotFound`.
final class EditStateCodableTests: XCTestCase {
    private func decode(_ json: String) throws -> EditState {
        try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
    }

    func testMissingFieldDecodesToItsDeclaredDefault() throws {
        // A "sidecar" that predates `sharpness` being added — every OTHER
        // field present and non-default, `sharpness` simply absent.
        let json = """
        {
            "whiteBalanceTemperature": 5000,
            "exposureEV": 1.5,
            "contrast": 0.3
        }
        """
        let state = try decode(json)

        XCTAssertEqual(state.whiteBalanceTemperature, 5000)
        XCTAssertEqual(state.exposureEV, 1.5)
        XCTAssertEqual(state.contrast, 0.3)
        // Every field NOT present in the JSON — including sharpness, and
        // every one of the ~58 others — must fall back to its own default,
        // not throw.
        XCTAssertEqual(state.sharpness, 0)
        XCTAssertEqual(state.defringePurple, 0)
        XCTAssertEqual(state.defringeGreen, 0)
        XCTAssertEqual(state.levelsWhitePoint, 1)
        XCTAssertEqual(state.vignetteRadius, 0.5)
        XCTAssertEqual(state.vignetteSoftness, 0, "a missing key must read as the original look")
        XCTAssertEqual(state.redEyeStrength, 0.7)
        XCTAssertEqual(state.masks, [])
        XCTAssertEqual(state.boostAmount, 1.0)
        XCTAssertEqual(state.rawExposureEV, 0)
        XCTAssertEqual(state.shadowBoostScale, 1.0)
        XCTAssertEqual(state.transformScale, 1.0)
        XCTAssertEqual(state.transformAspect, 0)
        XCTAssertEqual(state.rawWhiteBalanceNeutralPoints, [])
        XCTAssertEqual(state.rawLuminanceNoiseReductionAdjust, 0)
        XCTAssertEqual(state.rawColorNoiseReductionScale, 1.0)
        XCTAssertEqual(state.rawSharpnessScale, 1.0)
        XCTAssertEqual(state.rawContrastAdjust, 0)
        XCTAssertEqual(state.rawDetailAdjust, 0)
        XCTAssertEqual(state.rawMoireReductionAdjust, 0)
        XCTAssertEqual(state.rawDecoderVersionPin, "")
    }

    func testBoostAmountDecodesWhenPresent() throws {
        let state = try decode("""
        { "boostAmount": 0.4 }
        """)
        XCTAssertEqual(state.boostAmount, 0.4)
    }

    func testRawExposureEVDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawExposureEV": 1.25 }
        """)
        XCTAssertEqual(state.rawExposureEV, 1.25)
    }

    func testShadowBoostScaleDecodesWhenPresent() throws {
        let state = try decode("""
        { "shadowBoostScale": 0.6 }
        """)
        XCTAssertEqual(state.shadowBoostScale, 0.6)
    }

    func testRawWhiteBalanceNeutralPointsDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawWhiteBalanceNeutralPoints": [{"x": 0.4, "y": 0.6}] }
        """)
        XCTAssertEqual(state.rawWhiteBalanceNeutralPoints, [RawNeutralPoint(x: 0.4, y: 0.6)])
    }

    func testRawLuminanceNoiseReductionAdjustDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawLuminanceNoiseReductionAdjust": 0.3 }
        """)
        XCTAssertEqual(state.rawLuminanceNoiseReductionAdjust, 0.3)
    }

    func testRawColorNoiseReductionScaleDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawColorNoiseReductionScale": 0.45 }
        """)
        XCTAssertEqual(state.rawColorNoiseReductionScale, 0.45)
    }

    func testRawSharpnessScaleDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawSharpnessScale": 0.55 }
        """)
        XCTAssertEqual(state.rawSharpnessScale, 0.55)
    }

    func testRawContrastAdjustDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawContrastAdjust": 0.35 }
        """)
        XCTAssertEqual(state.rawContrastAdjust, 0.35)
    }

    func testRawDetailAdjustDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawDetailAdjust": 1.5 }
        """)
        XCTAssertEqual(state.rawDetailAdjust, 1.5)
    }

    func testRawMoireReductionAdjustDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawMoireReductionAdjust": 0.65 }
        """)
        XCTAssertEqual(state.rawMoireReductionAdjust, 0.65)
    }

    func testRawDecoderVersionPinDecodesWhenPresent() throws {
        let state = try decode("""
        { "rawDecoderVersionPin": "7" }
        """)
        XCTAssertEqual(state.rawDecoderVersionPin, "7")
    }

    /// Reviewer-requested (Phase 6 slice 7, round 2): `isEffectivelyIdentity`
    /// is the one thing standing between a RAW photo's invisible decoder-
    /// version pin and a permanently-enabled Revert-to-Original button —
    /// see its own doc comment and `ContentView`'s call site.
    func testIsEffectivelyIdentityTrueWhenOnlyTheDecoderPinDiffers() {
        var state = EditState.identity
        state.rawDecoderVersionPin = "7"
        XCTAssertTrue(state.isEffectivelyIdentity)
    }

    func testIsEffectivelyIdentityFalseWhenARealFieldAlsoDiffers() {
        var state = EditState.identity
        state.rawDecoderVersionPin = "7"
        state.exposureEV = 0.5
        XCTAssertFalse(state.isEffectivelyIdentity)
    }

    func testEmptyObjectDecodesToExactIdentity() throws {
        let state = try decode("{}")
        XCTAssertEqual(state, .identity)
    }

    func testUnknownExtraKeyIsIgnoredNotAnError() throws {
        // Simulates a NEWER sidecar (from a future field this app doesn't
        // know about yet) being read by today's logic — must decode fine,
        // not choke on the unrecognized key.
        let json = """
        {
            "exposureEV": 2.0,
            "someFutureFieldThatDoesNotExistYet": 42
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.exposureEV, 2.0)
    }

    // MARK: - Point Curve (Curves v2)
    //
    // `toneCurvePoints` decodes with `try?`, unlike the bare `try` on
    // `redEyePoints`/`masks` beside it. The two "does not discard the
    // sidecar" tests below are the entire justification for that deviation
    // — they are what fails under a bare `try`.

    func testToneCurvePointsDefaultToEmptyWhenAbsent() throws {
        XCTAssertEqual(try decode("{}").toneCurvePoints, [])
    }

    func testToneCurvePointsDecodeWhenPresent() throws {
        let json = """
        {
            "toneCurvePoints": [{"x": 0, "y": 0}, {"x": 0.5, "y": 0.72}, {"x": 1, "y": 1}]
        }
        """
        XCTAssertEqual(try decode(json).toneCurvePoints, [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.72),
            ToneCurvePoint(x: 1, y: 1)
        ])
    }

    func testToneCurvePointsRoundTripThroughASidecar() throws {
        var state = EditState()
        state.toneCurvePoints = [
            ToneCurvePoint(x: 0, y: 0.04),
            ToneCurvePoint(x: 0.42, y: 0.58),
            ToneCurvePoint(x: 1, y: 0.96)
        ]
        let reencoded = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reencoded.toneCurvePoints, state.toneCurvePoints)
    }

    func testAMalformedToneCurvePointDoesNotDiscardTheWholeSidecar() throws {
        // The whole sidecar read is wrapped in `try?` by the caller, so a
        // throw here would silently discard EVERY edit on the photo. One
        // bad point must cost the curve, not the photo.
        let json = """
        {
            "exposureEV": 2.0,
            "curvesShadows": 0.5,
            "toneCurvePoints": [{"x": 0, "y": 0}, {"x": 0.5}]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.exposureEV, 2.0, "other edits must survive a malformed curve")
        XCTAssertEqual(state.curvesShadows, 0.5)
        XCTAssertEqual(state.toneCurvePoints, [], "the curve alone is dropped")
    }

    func testToneCurvePointsWithAWrongJSONTypeDoesNotDiscardTheWholeSidecar() throws {
        let state = try decode("""
        { "exposureEV": 1.5, "toneCurvePoints": 5 }
        """)
        XCTAssertEqual(state.exposureEV, 1.5)
        XCTAssertEqual(state.toneCurvePoints, [])
    }

    func testStateWithAToneCurveIsNotEffectivelyIdentity() throws {
        var state = EditState()
        state.toneCurvePoints = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        XCTAssertFalse(state.isEffectivelyIdentity)
    }

    // MARK: - Per-channel point curves (Curves v2 slice 3)
    //
    // Same tolerant-per-field `try?` shape as `toneCurvePoints` above, now
    // three more times — the field under test in each case is what
    // changes, the reasoning does not.

    func testPerChannelCurvesDefaultToEmptyWhenAbsent() throws {
        let state = try decode("{}")
        XCTAssertEqual(state.toneCurvePointsRed, [])
        XCTAssertEqual(state.toneCurvePointsGreen, [])
        XCTAssertEqual(state.toneCurvePointsBlue, [])
    }

    func testPerChannelCurvesDecodeIndependently() throws {
        let json = """
        {
            "toneCurvePointsRed": [{"x": 0, "y": 0}, {"x": 0.5, "y": 0.7}, {"x": 1, "y": 1}],
            "toneCurvePointsGreen": [{"x": 0, "y": 0}, {"x": 0.5, "y": 0.3}, {"x": 1, "y": 1}],
            "toneCurvePointsBlue": [{"x": 0, "y": 0.1}, {"x": 1, "y": 0.9}]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.toneCurvePointsRed, [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.7), ToneCurvePoint(x: 1, y: 1),
        ])
        XCTAssertEqual(state.toneCurvePointsGreen, [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.3), ToneCurvePoint(x: 1, y: 1),
        ])
        XCTAssertEqual(state.toneCurvePointsBlue, [ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 1, y: 0.9)])
    }

    func testPerChannelCurvesRoundTripThroughASidecar() throws {
        var state = EditState()
        state.toneCurvePointsRed = [ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 1, y: 0.9)]
        state.toneCurvePointsGreen = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        state.toneCurvePointsBlue = [ToneCurvePoint(x: 0, y: 0.05), ToneCurvePoint(x: 1, y: 0.95)]
        let reencoded = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reencoded.toneCurvePointsRed, state.toneCurvePointsRed)
        XCTAssertEqual(reencoded.toneCurvePointsGreen, state.toneCurvePointsGreen)
        XCTAssertEqual(reencoded.toneCurvePointsBlue, state.toneCurvePointsBlue)
    }

    /// The whole point of decoding each channel with its OWN `try?`,
    /// rather than one `try?` around all three read together: a malformed
    /// RED curve must cost only the red curve, not the green/blue curves,
    /// and not the rest of the photo's edits.
    func testAMalformedChannelCurveDoesNotDiscardTheOtherChannelsOrTheSidecar() throws {
        let json = """
        {
            "exposureEV": 2.0,
            "toneCurvePointsRed": [{"x": 0, "y": 0}, {"x": 0.5}],
            "toneCurvePointsGreen": [{"x": 0, "y": 0.2}, {"x": 1, "y": 0.8}],
            "toneCurvePointsBlue": [{"x": 0, "y": 0}, {"x": 1, "y": 1}]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.exposureEV, 2.0, "other edits must survive a malformed channel curve")
        XCTAssertEqual(state.toneCurvePointsRed, [], "only the malformed channel's curve is dropped")
        XCTAssertEqual(state.toneCurvePointsGreen, [ToneCurvePoint(x: 0, y: 0.2), ToneCurvePoint(x: 1, y: 0.8)])
        XCTAssertEqual(state.toneCurvePointsBlue, [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)])
    }

    func testPerChannelCurveWithAWrongJSONTypeDoesNotDiscardTheWholeSidecar() throws {
        let state = try decode("""
        { "exposureEV": 1.5, "toneCurvePointsGreen": 5 }
        """)
        XCTAssertEqual(state.exposureEV, 1.5)
        XCTAssertEqual(state.toneCurvePointsGreen, [])
    }

    func testStateWithAPerChannelCurveIsNotEffectivelyIdentity() throws {
        var state = EditState()
        state.toneCurvePointsBlue = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        XCTAssertFalse(state.isEffectivelyIdentity)
    }

    func testRedEyePointsArrayDefaultsWhenAbsent() throws {
        let state = try decode("{}")
        XCTAssertEqual(state.redEyePoints, [])
    }

    func testRedEyePointsArrayDecodesWhenPresent() throws {
        let json = """
        {
            "redEyePoints": [{"x": 0.3, "y": 0.4}, {"x": 0.6, "y": 0.65}]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.redEyePoints, [
            RedEyePoint(x: 0.3, y: 0.4),
            RedEyePoint(x: 0.6, y: 0.65)
        ])
    }

    func testMasksArrayDefaultsWhenAbsent() throws {
        let state = try decode("{}")
        XCTAssertEqual(state.masks, [])
    }

    func testMasksArrayDecodesWhenPresent() throws {
        let json = """
        {
            "masks": [{
                "kind": "linear", "width": 0.4,
                "centerX": 0.3, "centerY": 0.4,
                "radiusX": 0.2, "radiusY": 0.15,
                "rotationDegrees": 10, "feather": 0.4,
                "exposureEV": 0.5, "contrast": 0.1, "highlights": -0.2, "shadows": 0.2,
                "clarity": 0.25, "saturation": 0.3, "temperature": 200, "tint": -10
            }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].kind, .linear)
        XCTAssertEqual(state.masks[0].width, 0.4)
        XCTAssertEqual(state.masks[0].centerX, 0.3)
        XCTAssertEqual(state.masks[0].exposureEV, 0.5)
        XCTAssertEqual(state.masks[0].tint, -10)
    }

    /// Slice 3: a `kind`/`width`-less mask JSON is exactly what every
    /// slice-2-era sidecar looks like on disk today — it MUST still
    /// decode to a `.radial` mask with `width` at its declared default,
    /// not throw, not silently become `.linear`.
    func testMaskKindAndWidthDefaultWhenAbsent() throws {
        let json = """
        { "masks": [{ "centerX": 0.3, "centerY": 0.4, "radiusX": 0.2, "radiusY": 0.15 }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks[0].kind, .radial)
        XCTAssertEqual(state.masks[0].width, 0.3)
    }

    /// The highest-severity hazard slice 3 introduces: `MaskKind` is a
    /// String-raw-value enum, so decoding it via
    /// `decodeIfPresent(MaskKind.self, forKey:)` would THROW on an
    /// unrecognized value (it only returns `nil` for an ABSENT key). Both
    /// sidecar readers in this app wrap the whole `EditState` decode in
    /// `try?`, so an uncaught throw here wouldn't just skip this one
    /// mask — it would discard the ENTIRE sidecar, every global edit on
    /// the photo included. Assert the fix directly: a sidecar with an
    /// unrecognized future kind string (`"cloudRange"`, standing in for a
    /// still-unbuilt future mask kind — `"depthRange"` stood in until the Depth
    /// Range mask became a real kind (2026-10-12); `"brush"`, `"luminanceRange"`, and now `"colorRange"`
    /// all became REAL, recognized kinds in slices 4/5, so none of them
    /// can stand in for "unrecognized" anymore — repointed off `"colorRange"`
    /// specifically when that slice shipped, per this test's own original
    /// warning) PLUS a non-default GLOBAL field must still decode
    /// successfully, with the global field intact — proving the
    /// whole-sidecar-loss hazard is actually closed, not just theorized.
    func testUnknownMaskKindDecodesToRadialWithoutDiscardingTheSidecar() throws {
        let json = """
        {
            "exposureEV": 1.5,
            "masks": [{ "kind": "cloudRange", "centerX": 0.6 }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.exposureEV, 1.5, "an unrecognized mask kind must not discard the rest of the sidecar")
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].kind, .radial)
        XCTAssertEqual(state.masks[0].centerX, 0.6)
    }

    /// Reviewer-caught (round 2): the sibling test above only covers an
    /// unrecognized but WELL-TYPED string. A hand-authored sidecar could
    /// just as easily encode `kind` as the wrong JSON TYPE entirely (a
    /// number here, standing in for any type mismatch) — decoding that
    /// via a bare `try container.decodeIfPresent(String.self, forKey:)`
    /// throws a `DecodingError` just as readily as an unrecognized value
    /// would, and would discard the whole sidecar the same way. This is
    /// the case that motivated wrapping that decode in `try?`.
    func testMaskKindWithWrongJSONTypeDecodesToRadialWithoutDiscardingTheSidecar() throws {
        let json = """
        {
            "contrast": 0.4,
            "masks": [{ "kind": 2, "centerX": 0.6 }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.contrast, 0.4, "a type-mismatched mask kind must not discard the rest of the sidecar")
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].kind, .radial)
        XCTAssertEqual(state.masks[0].centerX, 0.6)
    }

    /// Phase 7 slice 4: `brushSize`/`brushPoints` default when absent, the
    /// same schema-tolerance every other `Mask` field already has (a
    /// pre-slice-4 sidecar has neither key at all).
    func testBrushSizeAndBrushPointsDefaultWhenAbsent() throws {
        let json = """
        { "masks": [{ "kind": "brush" }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].brushSize, 0.05, accuracy: 0.0001)
        XCTAssertEqual(state.masks[0].brushPoints, [])
    }

    /// Same whole-sidecar-loss hazard `testMaskKindWithWrongJSONTypeDecodesToRadialWithoutDiscardingTheSidecar`
    /// already covers for `kind`, one field over: a malformed POINT inside
    /// `brushPoints` (missing `y`) must not throw and discard the entire
    /// sidecar — `Mask.init(from:)` decodes this array via `try?`
    /// specifically to close this.
    func testMalformedBrushPointDoesNotDiscardTheSidecar() throws {
        let json = """
        {
            "exposureEV": 1.5,
            "masks": [{ "kind": "brush", "brushPoints": [{ "x": 0.1 }] }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.exposureEV, 1.5, "a malformed brush point must not discard the rest of the sidecar")
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].kind, .brush)
        XCTAssertEqual(state.masks[0].brushPoints, [], "the malformed array falls back to empty, not a partial/garbage decode")
    }

    /// A `.brush` mask's new fields must survive an encode/decode
    /// round-trip, the same guarantee already exercised for `.radial`/
    /// `.linear`'s own geometry fields.
    func testBrushMaskRoundTripsThroughCodable() throws {
        let original = Mask(
            kind: .brush, feather: 0.7, brushSize: 0.12,
            brushPoints: [BrushPoint(x: 0.1, y: 0.2), BrushPoint(x: 0.3, y: 0.4)],
            exposureEV: 1.2
        )
        let data = try JSONEncoder().encode(EditState(masks: [original]))
        let decoded = try JSONDecoder().decode(EditState.self, from: data)
        XCTAssertEqual(decoded.masks.count, 1)
        XCTAssertEqual(decoded.masks[0].kind, .brush)
        XCTAssertEqual(decoded.masks[0].brushSize, 0.12, accuracy: 0.0001)
        XCTAssertEqual(decoded.masks[0].brushPoints, original.brushPoints)
        XCTAssertEqual(decoded.masks[0].id, original.id)
    }

    /// `kind` must feed `Mask`'s deterministic id-fallback hash — omitting
    /// it would let a default id-less `.radial` mask and a default
    /// id-less `.linear` mask collide on the SAME id, breaking
    /// `ForEach`/`delete(_:)` identity for two masks that are visibly
    /// different (unlike the ALREADY-accepted collision case of two
    /// field-identical, hence visually-identical, masks).
    func testIdLessRadialAndLinearMasksWithIdenticalFieldsGetDifferentIds() throws {
        let json = """
        {
            "masks": [
                { "centerX": 0.4, "centerY": 0.4 },
                { "kind": "linear", "centerX": 0.4, "centerY": 0.4 }
            ]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 2)
        XCTAssertNotEqual(state.masks[0].id, state.masks[1].id)
    }

    func testRepeatedDecodesOfTheSameIdLessLinearMaskAreEqual() throws {
        let json = """
        { "masks": [{ "kind": "linear", "centerX": 0.4, "centerY": 0.6, "width": 0.4, "rotationDegrees": 30 }] }
        """
        let first = try decode(json).masks[0]
        let second = try decode(json).masks[0]
        XCTAssertEqual(first.id, second.id)
    }

    /// Phase 7 slice 4: `deterministicFallbackID` mixes `brushPoints` in as
    /// a second pass after the fixed-arity scalar fields (`Mask.swift`'s
    /// own doc comment) — two id-less brush masks differing ONLY in their
    /// points must not collide on the same id, the same reasoning
    /// `testIdLessRadialAndLinearMasksWithIdenticalFieldsGetDifferentIds`
    /// already established for `kind`.
    func testIdLessBrushMasksWithDifferentPointsGetDifferentIds() throws {
        let json = """
        {
            "masks": [
                { "kind": "brush", "brushPoints": [{ "x": 0.1, "y": 0.1 }] },
                { "kind": "brush", "brushPoints": [{ "x": 0.9, "y": 0.9 }] }
            ]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 2)
        XCTAssertNotEqual(state.masks[0].id, state.masks[1].id)
    }

    func testRepeatedDecodesOfTheSameIdLessBrushMaskAreEqual() throws {
        let json = """
        { "masks": [{ "kind": "brush", "brushSize": 0.2, "brushPoints": [{ "x": 0.3, "y": 0.4 }, { "x": 0.5, "y": 0.6 }] }] }
        """
        let first = try decode(json).masks[0]
        let second = try decode(json).masks[0]
        XCTAssertEqual(first.id, second.id)
    }

    /// Phase 7 slice 5: `luminanceTarget`/`luminanceRange` default when
    /// absent, the same schema-tolerance every other `Mask` field already
    /// has (a pre-slice-5 sidecar has neither key at all).
    func testLuminanceTargetAndLuminanceRangeDefaultWhenAbsent() throws {
        let json = """
        { "masks": [{ "kind": "luminanceRange" }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].luminanceTarget, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.masks[0].luminanceRange, 0.3, accuracy: 0.0001)
    }

    /// A `.luminanceRange` mask's new fields must survive an encode/decode
    /// round-trip, the same guarantee already exercised for `.radial`/
    /// `.linear`/`.brush`'s own geometry fields.
    func testLuminanceRangeMaskRoundTripsThroughCodable() throws {
        let original = Mask(
            kind: .luminanceRange, feather: 0.7,
            luminanceTarget: 0.72, luminanceRange: 0.18,
            exposureEV: -0.8
        )
        let data = try JSONEncoder().encode(EditState(masks: [original]))
        let decoded = try JSONDecoder().decode(EditState.self, from: data)
        XCTAssertEqual(decoded.masks.count, 1)
        XCTAssertEqual(decoded.masks[0].kind, .luminanceRange)
        XCTAssertEqual(decoded.masks[0].luminanceTarget, 0.72, accuracy: 0.0001)
        XCTAssertEqual(decoded.masks[0].luminanceRange, 0.18, accuracy: 0.0001)
        XCTAssertEqual(decoded.masks[0].id, original.id)
    }

    /// Phase 7 slice 5: `deterministicFallbackID` mixes `luminanceTarget`/
    /// `luminanceRange` in as fixed-arity scalars, and `.luminanceRange`
    /// gets its own `kindSeed` — an id-less `.luminanceRange` mask must not
    /// collide with an id-less `.radial`/`.linear`/`.brush` mask that
    /// happens to share the same (default) adjustment values, the same
    /// reasoning `testIdLessRadialAndLinearMasksWithIdenticalFieldsGetDifferentIds`
    /// already established for the first two kinds.
    func testIdLessLuminanceRangeAndRadialMasksGetDifferentIds() throws {
        let json = """
        { "masks": [
            { "kind": "luminanceRange" },
            { "kind": "radial" }
        ] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 2)
        XCTAssertNotEqual(state.masks[0].id, state.masks[1].id)
    }

    func testRepeatedDecodesOfTheSameIdLessLuminanceRangeMaskAreEqual() throws {
        let json = """
        { "masks": [{ "kind": "luminanceRange", "luminanceTarget": 0.65, "luminanceRange": 0.2 }] }
        """
        let first = try decode(json).masks[0]
        let second = try decode(json).masks[0]
        XCTAssertEqual(first.id, second.id)
    }

    /// Phase 7 slice 5 second half: `colorRangeTargetHue`/
    /// `colorRangeTargetSaturation`/`colorRangeTargetLuminance`/
    /// `colorRangeTolerance`/`colorRangeHasTarget` default when absent, the
    /// same schema-tolerance every other `Mask` field already has (a
    /// pre-slice-5-second-half sidecar has none of these keys at all).
    func testColorRangeFieldsDefaultWhenAbsent() throws {
        let json = """
        { "masks": [{ "kind": "colorRange" }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].colorRangeTargetHue, 0, accuracy: 0.0001)
        XCTAssertEqual(state.masks[0].colorRangeTargetSaturation, 0, accuracy: 0.0001)
        XCTAssertEqual(state.masks[0].colorRangeTargetLuminance, 0, accuracy: 0.0001)
        XCTAssertEqual(state.masks[0].colorRangeTolerance, 0.3, accuracy: 0.0001)
        XCTAssertFalse(state.masks[0].colorRangeHasTarget)
    }

    /// A `.colorRange` mask's new fields must survive an encode/decode
    /// round-trip, the same guarantee already exercised for every other
    /// kind's own geometry/selection fields.
    func testColorRangeMaskRoundTripsThroughCodable() throws {
        let original = Mask(
            kind: .colorRange, feather: 0.6,
            colorRangeTargetHue: 210, colorRangeTargetSaturation: 0.5, colorRangeTargetLuminance: 0.22,
            colorRangeTolerance: 0.45, colorRangeHasTarget: true,
            exposureEV: -0.4
        )
        let data = try JSONEncoder().encode(EditState(masks: [original]))
        let decoded = try JSONDecoder().decode(EditState.self, from: data)
        XCTAssertEqual(decoded.masks.count, 1)
        XCTAssertEqual(decoded.masks[0].kind, .colorRange)
        XCTAssertEqual(decoded.masks[0].colorRangeTargetHue, 210, accuracy: 0.0001)
        XCTAssertEqual(decoded.masks[0].colorRangeTargetSaturation, 0.5, accuracy: 0.0001)
        XCTAssertEqual(decoded.masks[0].colorRangeTargetLuminance, 0.22, accuracy: 0.0001)
        XCTAssertEqual(decoded.masks[0].colorRangeTolerance, 0.45, accuracy: 0.0001)
        XCTAssertTrue(decoded.masks[0].colorRangeHasTarget)
        XCTAssertEqual(decoded.masks[0].id, original.id)
    }

    /// `deterministicFallbackID` mixes `kind` in first — an id-less
    /// `.colorRange` mask must not collide with an id-less `.luminanceRange`
    /// mask that happens to share every other (default) field value, the
    /// same reasoning `testIdLessLuminanceRangeAndRadialMasksGetDifferentIds`
    /// already established for the previous kind addition.
    func testIdLessColorRangeAndLuminanceRangeMasksGetDifferentIds() throws {
        let json = """
        { "masks": [
            { "kind": "colorRange" },
            { "kind": "luminanceRange" }
        ] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 2)
        XCTAssertNotEqual(state.masks[0].id, state.masks[1].id)
    }

    /// `colorRangeHasTarget` must itself feed the hash, not just the three
    /// scalars it gates (see that field's own doc comment) — an id-less
    /// mask with a picked color must not collide with an otherwise-
    /// identical id-less mask that hasn't picked one yet.
    func testIdLessColorRangeMasksDifferingOnlyInHasTargetGetDifferentIds() throws {
        let json = """
        { "masks": [
            { "kind": "colorRange", "colorRangeHasTarget": true },
            { "kind": "colorRange", "colorRangeHasTarget": false }
        ] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 2)
        XCTAssertNotEqual(state.masks[0].id, state.masks[1].id)
    }

    func testRepeatedDecodesOfTheSameIdLessColorRangeMaskAreEqual() throws {
        let json = """
        { "masks": [{ "kind": "colorRange", "colorRangeTargetHue": 88, "colorRangeHasTarget": true }] }
        """
        let first = try decode(json).masks[0]
        let second = try decode(json).masks[0]
        XCTAssertEqual(first.id, second.id)
    }

    // MARK: - Combining (Phase 7 slice 6)

    /// `combineMode`/`combineWithMaskID` default when absent, the same
    /// schema-tolerance every other `Mask` field already has (a
    /// pre-slice-6 sidecar has neither key at all). `.none`/`nil` is what
    /// makes slice 6 purely additive — a pre-slice-6 mask renders exactly
    /// as it always has.
    func testCombineFieldsDefaultWhenAbsent() throws {
        let json = """
        { "masks": [{ "kind": "radial" }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].combineMode, .none)
        XCTAssertNil(state.masks[0].combineWithMaskID)
    }

    /// A mask's combine mode/target must survive an encode/decode
    /// round-trip, the same guarantee already exercised for every other
    /// kind's own fields.
    func testCombineFieldsRoundTripThroughCodable() throws {
        let targetID = UUID()
        let original = Mask(kind: .radial, combineMode: .subtract, combineWithMaskID: targetID)
        let data = try JSONEncoder().encode(EditState(masks: [original]))
        let decoded = try JSONDecoder().decode(EditState.self, from: data)
        XCTAssertEqual(decoded.masks.count, 1)
        XCTAssertEqual(decoded.masks[0].combineMode, .subtract)
        XCTAssertEqual(decoded.masks[0].combineWithMaskID, targetID)
        XCTAssertEqual(decoded.masks[0].id, original.id)
    }

    /// `MaskCombineMode` is a String-raw-value enum — the exact `kind`
    /// hazard: `decodeIfPresent` THROWS on a present-but-unrecognized raw
    /// value (it only returns `nil` for an ABSENT key). Both sidecar
    /// readers in this app wrap the whole `EditState` decode in `try?`, so
    /// an uncaught throw here would discard the ENTIRE sidecar, not just
    /// this one mask's combine setting.
    func testUnknownCombineModeDecodesToNoneWithoutDiscardingTheSidecar() throws {
        let json = """
        {
            "exposureEV": 1.5,
            "masks": [{ "kind": "radial", "combineMode": "xor" }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.exposureEV, 1.5, "an unrecognized combine mode must not discard the rest of the sidecar")
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].combineMode, .none)
    }

    func testCombineModeWithWrongJSONTypeDecodesToNoneWithoutDiscardingTheSidecar() throws {
        let json = """
        {
            "contrast": 0.4,
            "masks": [{ "kind": "radial", "combineMode": 2 }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.contrast, 0.4, "a type-mismatched combine mode must not discard the rest of the sidecar")
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].combineMode, .none)
    }

    /// `combineWithMaskID` looks like a plain-scalar field but isn't one:
    /// `UUID.init(from:)` throws on a well-typed-but-unparseable string
    /// (e.g. a hand-typed `"mask-3"`) — the same hazard class as
    /// `combineMode`'s own unrecognized-value throw, and more reachable
    /// (a user hand-editing a combine reference by id is exactly the
    /// person likely to type a non-UUID there). This is the test that
    /// justifies the `try?` choice for this field in `Mask.init(from:)`.
    func testMalformedCombineWithMaskIDDoesNotDiscardTheSidecar() throws {
        let json = """
        {
            "exposureEV": -0.5,
            "masks": [{ "kind": "radial", "combineWithMaskID": "mask-3" }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.exposureEV, -0.5, "a malformed combine target must not discard the rest of the sidecar")
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertNil(state.masks[0].combineWithMaskID)
    }

    func testCombineWithMaskIDWithWrongJSONTypeDoesNotDiscardTheSidecar() throws {
        let json = """
        {
            "hslSaturation": 0.2,
            "masks": [{ "kind": "radial", "combineWithMaskID": 42 }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(
            state.hslSaturation, 0.2, "a type-mismatched combine target must not discard the rest of the sidecar"
        )
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertNil(state.masks[0].combineWithMaskID)
    }

    /// `deterministicFallbackID` mixes `combineMode` in as a fixed-arity
    /// scalar (`0`/`1`/`2`) — an id-less mask differing only in combine
    /// mode must not collide with an otherwise-identical id-less mask at
    /// the default `.none`.
    func testIdLessMasksDifferingOnlyInCombineModeGetDifferentIds() throws {
        let json = """
        { "masks": [
            { "kind": "radial", "combineMode": "intersect" },
            { "kind": "radial" }
        ] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 2)
        XCTAssertNotEqual(state.masks[0].id, state.masks[1].id)
    }

    /// `deterministicFallbackID` mixes `combineWithMaskID` in as a THIRD
    /// variable-length pass (after `brushPoints`' own) — an id-less mask
    /// differing only in combine TARGET must not collide with one that has
    /// no target at all, or with one targeting a different mask.
    func testIdLessMasksDifferingOnlyInCombineTargetGetDifferentIds() throws {
        let targetA = UUID()
        let targetB = UUID()
        let json = """
        { "masks": [
            { "kind": "radial", "combineMode": "intersect" },
            { "kind": "radial", "combineMode": "intersect", "combineWithMaskID": "\(targetA.uuidString)" },
            { "kind": "radial", "combineMode": "intersect", "combineWithMaskID": "\(targetB.uuidString)" }
        ] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 3)
        XCTAssertNotEqual(state.masks[0].id, state.masks[1].id)
        XCTAssertNotEqual(state.masks[0].id, state.masks[2].id)
        XCTAssertNotEqual(state.masks[1].id, state.masks[2].id)
    }

    func testRepeatedDecodesOfTheSameIdLessCombiningMaskAreEqual() throws {
        let targetID = UUID()
        let json = """
        { "masks": [{ "kind": "radial", "combineMode": "subtract", "combineWithMaskID": "\(targetID.uuidString)" }] }
        """
        let first = try decode(json).masks[0]
        let second = try decode(json).masks[0]
        XCTAssertEqual(first.id, second.id)
    }

    /// The genuinely new coverage this slice adds: `Mask` needs its OWN
    /// schema-tolerant decoding one level down from `EditState`'s (see
    /// `Mask.swift`'s own doc comment) — a mask JSON missing most of its
    /// keys (as a future slice's field additions would produce for an
    /// older saved mask) must decode to each field's declared default, not
    /// throw.
    func testMaskWithMissingParamKeysDecodesToItsDeclaredDefaults() throws {
        let json = """
        { "masks": [{ "centerX": 0.7 }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks.count, 1)
        let mask = state.masks[0]
        XCTAssertEqual(mask.kind, .radial)
        XCTAssertEqual(mask.centerX, 0.7)
        XCTAssertEqual(mask.centerY, 0.5)
        XCTAssertEqual(mask.radiusX, 0.25)
        XCTAssertEqual(mask.radiusY, 0.25)
        XCTAssertEqual(mask.rotationDegrees, 0)
        XCTAssertEqual(mask.feather, 0.5)
        XCTAssertEqual(mask.width, 0.3)
        XCTAssertEqual(mask.exposureEV, 0)
        XCTAssertEqual(mask.contrast, 0)
        XCTAssertEqual(mask.highlights, 0)
        XCTAssertEqual(mask.shadows, 0)
        XCTAssertEqual(mask.clarity, 0)
        XCTAssertEqual(mask.saturation, 0)
        XCTAssertEqual(mask.temperature, 0)
        XCTAssertEqual(mask.tint, 0)
        XCTAssertTrue(mask.isIdentity)
    }

    func testMaskIDRoundTripsThroughCodable() throws {
        let id = UUID()
        let mask = Mask(id: id, centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2)
        var state = EditState()
        state.masks = [mask]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(decoded.masks[0].id, id)
    }

    func testMaskUnknownExtraKeyIsIgnoredNotAnError() throws {
        let json = """
        { "masks": [{ "centerX": 0.6, "someFutureMaskFieldThatDoesNotExistYet": 42 }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.masks[0].centerX, 0.6)
    }

    /// The deliberate asymmetry `Mask.isIdentity`'s own doc comment
    /// describes: a mask that is placed (real geometry) but has every
    /// adjustment param at 0 renders byte-identical to no mask, yet the
    /// STATE holding it is not `isEffectivelyIdentity` — mirroring
    /// `redEyePoints`' existing behavior (a placed point with strength 0
    /// still counts as an edit).
    func testStateWithAnIdentityParamMaskIsNotEffectivelyIdentity() {
        var state = EditState.identity
        state.masks = [Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.25, radiusY: 0.25)]
        XCTAssertTrue(state.masks[0].isIdentity, "sanity check: the mask itself has every param at identity")
        XCTAssertFalse(state.isEffectivelyIdentity)
    }

    // MARK: - Point Color

    func testPointColorsArrayDefaultsWhenAbsent() throws {
        let state = try decode("{}")
        XCTAssertEqual(state.pointColors, [])
    }

    func testPointColorsArrayDecodesWhenPresent() throws {
        let json = """
        {
            "pointColors": [{
                "hasTarget": true, "targetHue": 120, "targetSaturation": 0.6, "range": 0.4,
                "hue": 0.5, "saturation": -0.3, "luminance": 0.2
            }]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.pointColors.count, 1)
        XCTAssertEqual(state.pointColors[0].hasTarget, true)
        XCTAssertEqual(state.pointColors[0].targetHue, 120)
        XCTAssertEqual(state.pointColors[0].targetSaturation, 0.6)
        XCTAssertEqual(state.pointColors[0].range, 0.4)
        XCTAssertEqual(state.pointColors[0].hue, 0.5)
        XCTAssertEqual(state.pointColors[0].saturation, -0.3)
        XCTAssertEqual(state.pointColors[0].luminance, 0.2)
    }

    func testPointColorWithMissingParamKeysDecodesToItsDeclaredDefaults() throws {
        let json = """
        { "pointColors": [{ "hue": 0.5 }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.pointColors.count, 1)
        let pointColor = state.pointColors[0]
        XCTAssertEqual(pointColor.hasTarget, false)
        XCTAssertEqual(pointColor.targetHue, 0)
        XCTAssertEqual(pointColor.targetSaturation, 0)
        XCTAssertEqual(pointColor.range, 0.5)
        XCTAssertEqual(pointColor.hue, 0.5)
        XCTAssertEqual(pointColor.saturation, 0)
        XCTAssertEqual(pointColor.luminance, 0)
    }

    func testPointColorIDRoundTripsThroughCodable() throws {
        let id = UUID()
        let pointColor = PointColor(id: id, hasTarget: true, targetHue: 30, targetSaturation: 0.5)
        var state = EditState()
        state.pointColors = [pointColor]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(decoded.pointColors[0].id, id)
    }

    func testPointColorUnknownExtraKeyIsIgnoredNotAnError() throws {
        let json = """
        { "pointColors": [{ "hue": 0.5, "someFutureFieldThatDoesNotExistYet": 42 }] }
        """
        let state = try decode(json)
        XCTAssertEqual(state.pointColors[0].hue, 0.5)
    }

    /// The deliberate asymmetry `PointColor.isIdentity`'s own doc comment
    /// describes: an instance with a picked target but every adjustment
    /// at 0 renders byte-identical to no instance at all, yet the STATE
    /// holding it is not `isEffectivelyIdentity` — mirroring `Mask`'s
    /// existing `testStateWithAnIdentityParamMaskIsNotEffectivelyIdentity`.
    func testStateWithAnIdentityPointColorIsNotEffectivelyIdentity() {
        var state = EditState.identity
        state.pointColors = [PointColor(hasTarget: true, targetHue: 30, targetSaturation: 0.5)]
        XCTAssertTrue(state.pointColors[0].isIdentity, "sanity check: every adjustment field is at identity")
        XCTAssertFalse(state.isEffectivelyIdentity)
    }

    func testFullyPopulatedJSONStillDecodesCorrectly() throws {
        // Sanity check that the custom decoder isn't ONLY correct in the
        // all-missing case — every field explicitly present should decode
        // to exactly that value, not silently fall back to a default.
        var expected = EditState()
        expected.blackAndWhite = true
        expected.flipHorizontal = true
        expected.cropInsetTop = 0.1

        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(decoded, expected)
    }

    // MARK: - Legacy `definition` -> `clarity` migration
    //
    // `definition` was a SHIPPED field, live in real sidecars on disk and in
    // saved presets (GRDB serializes `Preset.editState` through this exact
    // decoder). The Texture/Clarity split replaced it. These tests are the
    // guard that the split did not silently reset every existing user's
    // Definition edit to zero — the one failure mode of this change that
    // nothing else would catch.

    func testLegacyDefinitionKeyDecodesIntoClarity() throws {
        // A sidecar written before the split.
        let state = try decode("""
        {
            "exposureEV": 0.5,
            "definition": 0.62
        }
        """)

        XCTAssertEqual(state.clarity, 0.62)
        XCTAssertEqual(state.texture, 0, "texture had no pre-split equivalent and must default to identity")
        XCTAssertEqual(state.exposureEV, 0.5)
    }

    func testExplicitClarityWinsOverLegacyDefinition() throws {
        // A file carrying BOTH (e.g. hand-edited, or written by a build
        // mid-migration): the current key must win, not the legacy one.
        let state = try decode("""
        {
            "definition": 0.2,
            "clarity": 0.9
        }
        """)

        XCTAssertEqual(state.clarity, 0.9)
    }

    func testAbsentDefinitionAndClarityBothDefaultToIdentity() throws {
        let state = try decode("""
        { "exposureEV": 1.0 }
        """)

        XCTAssertEqual(state.clarity, 0)
        XCTAssertEqual(state.texture, 0)
    }

    func testLegacyDefinitionSurvivesAFullEncodeDecodeRoundTrip() throws {
        // The realistic upgrade path: an old sidecar is read, the app later
        // re-saves it, and the value must still be there afterwards under
        // the new key. Also pins that `definition` is no longer WRITTEN.
        let decoded = try decode("""
        { "definition": 0.45 }
        """)
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(EditState.self, from: reencoded)

        XCTAssertEqual(roundTripped.clarity, 0.45)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertNotNil(json["clarity"], "clarity must be written under its own key")
        XCTAssertNil(json["definition"], "the legacy key is read-only — it must not be re-emitted")
    }

    func testNegativeClarityRoundTripsThroughASidecar() throws {
        // The negative half is new (the pre-split field was 0...1), so a
        // negative value is exactly the kind of thing a clamping bug in
        // serialization would silently swallow.
        let original = EditState(texture: -0.8, clarity: -0.35)
        let roundTripped = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(roundTripped.clarity, -0.35)
        XCTAssertEqual(roundTripped.texture, -0.8)
    }

    func testDehazeRoundTripsIncludingNegativeValues() throws {
        // Purely additive field (no legacy key, unlike clarity), so the only
        // real risk is a clamp swallowing the negative half.
        let original = EditState(texture: 0.2, clarity: -0.4, dehaze: -0.75)
        let roundTripped = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(roundTripped.dehaze, -0.75)
        XCTAssertEqual(roundTripped.clarity, -0.4)
        XCTAssertEqual(roundTripped.texture, 0.2)
    }

    func testDehazeAbsentFromAnOlderSidecarDefaultsToIdentity() throws {
        let state = try decode("""
        { "clarity": 0.5 }
        """)

        XCTAssertEqual(state.dehaze, 0)
        XCTAssertEqual(state.clarity, 0.5)
    }

    func testGrainRoundTrips() throws {
        // Purely additive field (no legacy key), same as dehaze.
        let original = EditState(sharpness: 0.4, grain: 0.65)
        let roundTripped = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(roundTripped.grain, 0.65)
        XCTAssertEqual(roundTripped.sharpness, 0.4)
    }

    func testGrainAbsentFromAnOlderSidecarDefaultsToIdentity() throws {
        let state = try decode("""
        { "sharpness": 0.3 }
        """)

        XCTAssertEqual(state.grain, 0)
        XCTAssertEqual(state.sharpness, 0.3)
    }

    /// The specific hazard this feature's own plan called out: `1.0`, not
    /// `0`, is `transformScale`'s identity — decoding a missing key to `0`
    /// would scale every pre-existing sidecar's photo to zero size the
    /// moment it's opened. `transformAspect`'s identity IS `0`, included
    /// here for contrast, not because it shares the hazard.
    func testTransformScaleAndAspectAbsentFromAnOlderSidecarDefaultToIdentity() throws {
        let state = try decode("""
        { "sharpness": 0.3 }
        """)

        XCTAssertEqual(state.transformScale, 1.0)
        XCTAssertEqual(state.transformAspect, 0)
        XCTAssertEqual(state.sharpness, 0.3)
    }

    func testColorGradingRoundTrips() throws {
        // Purely additive fields (no legacy keys), same as dehaze/grain.
        var original = EditState()
        original.shadowHue = 210
        original.shadowSaturation = 0.6
        original.shadowLuminance = -0.3
        original.midtoneHue = 30
        original.midtoneSaturation = 0.4
        original.midtoneLuminance = 0.2
        original.highlightHue = 50
        original.highlightSaturation = 0.5
        original.highlightLuminance = 0.1
        original.colorGradingBlending = 0.4
        original.colorGradingBalance = -0.6
        let roundTripped = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(roundTripped.shadowHue, 210)
        XCTAssertEqual(roundTripped.shadowSaturation, 0.6)
        XCTAssertEqual(roundTripped.shadowLuminance, -0.3)
        XCTAssertEqual(roundTripped.midtoneHue, 30)
        XCTAssertEqual(roundTripped.midtoneSaturation, 0.4)
        XCTAssertEqual(roundTripped.midtoneLuminance, 0.2)
        XCTAssertEqual(roundTripped.highlightHue, 50)
        XCTAssertEqual(roundTripped.highlightSaturation, 0.5)
        XCTAssertEqual(roundTripped.highlightLuminance, 0.1)
        XCTAssertEqual(roundTripped.colorGradingBlending, 0.4)
        XCTAssertEqual(roundTripped.colorGradingBalance, -0.6)
    }

    func testColorGradingAbsentFromAnOlderSidecarDefaultsToIdentity() throws {
        let state = try decode("""
        { "sharpness": 0.3 }
        """)

        XCTAssertEqual(state.shadowHue, 0)
        XCTAssertEqual(state.shadowSaturation, 0)
        XCTAssertEqual(state.shadowLuminance, 0)
        XCTAssertEqual(state.midtoneHue, 0)
        XCTAssertEqual(state.midtoneSaturation, 0)
        XCTAssertEqual(state.midtoneLuminance, 0)
        XCTAssertEqual(state.highlightHue, 0)
        XCTAssertEqual(state.highlightSaturation, 0)
        XCTAssertEqual(state.highlightLuminance, 0)
        XCTAssertEqual(state.colorGradingBlending, 0, "a missing key must decode to the original look, never to a narrower width")
        XCTAssertEqual(state.colorGradingBalance, 0)
        XCTAssertEqual(state.sharpness, 0.3)
    }

    // MARK: - ImageDocumentModel.sidecarURL(for:)

    func testSidecarURLAppendsPhotoAppJSONSuffix() {
        let photoURL = URL(fileURLWithPath: "/Users/test/Desktop/MyPhoto.jpg")
        let sidecar = ImageDocumentModel.sidecarURL(for: photoURL)
        XCTAssertEqual(sidecar.path, "/Users/test/Desktop/MyPhoto.jpg.photoapp.json")
    }

    func testSidecarURLStaysInTheSameDirectory() {
        let photoURL = URL(fileURLWithPath: "/Users/test/Pictures/Vacation/IMG_0001.HEIC")
        let sidecar = ImageDocumentModel.sidecarURL(for: photoURL)
        XCTAssertEqual(sidecar.deletingLastPathComponent().path, "/Users/test/Pictures/Vacation")
    }

    func testSidecarURLHandlesFilenameWithNoExtension() {
        let photoURL = URL(fileURLWithPath: "/Users/test/Downloads/photo")
        let sidecar = ImageDocumentModel.sidecarURL(for: photoURL)
        XCTAssertEqual(sidecar.lastPathComponent, "photo.photoapp.json")
    }
}
