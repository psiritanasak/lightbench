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
        XCTAssertEqual(state.levelsWhitePoint, 1)
        XCTAssertEqual(state.vignetteRadius, 0.5)
        XCTAssertEqual(state.redEyeStrength, 0.7)
        XCTAssertEqual(state.masks, [])
        XCTAssertEqual(state.boostAmount, 1.0)
        XCTAssertEqual(state.rawExposureEV, 0)
        XCTAssertEqual(state.shadowBoostScale, 1.0)
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
    /// unrecognized future kind string (`"brush"`, standing in for a
    /// hypothetical slice-4 kind) PLUS a non-default GLOBAL field must
    /// still decode successfully, with the global field intact — proving
    /// the whole-sidecar-loss hazard is actually closed, not just
    /// theorized.
    func testUnknownMaskKindDecodesToRadialWithoutDiscardingTheSidecar() throws {
        let json = """
        {
            "exposureEV": 1.5,
            "masks": [{ "kind": "brush", "centerX": 0.6 }]
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
