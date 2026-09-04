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
