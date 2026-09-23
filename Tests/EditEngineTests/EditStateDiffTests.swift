import XCTest
@testable import PhotoApp

/// Verifies `EditStateDiff`'s `Mirror`-based field comparison — in
/// particular that it agrees with `EditState`'s own compiler-synthesized
/// `==` (opened `Equatable`, not `String(describing:)`), and the generic
/// camelCase → "Title Case" `displayName` prettifier.
final class EditStateDiffTests: XCTestCase {
    func testIdenticalStatesHaveNoChangedFields() {
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: .identity, to: .identity), [])
    }

    func testASingleChangedDoubleFieldIsDetected() {
        var new = EditState.identity
        new.exposureEV = 1.0
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: .identity, to: new), ["exposureEV"])
    }

    func testASingleChangedBoolFieldIsDetected() {
        var new = EditState.identity
        new.blackAndWhite = true
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: .identity, to: new), ["blackAndWhite"])
    }

    func testAChangedArrayFieldIsDetected() {
        var new = EditState.identity
        new.toneCurvePoints = [ToneCurvePoint(x: 0.5, y: 0.6)]
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: .identity, to: new), ["toneCurvePoints"])
    }

    /// Pins the opened-`Equatable` design specifically: two `[Mask]` arrays
    /// that differ only inside ONE mask's own field must still be reported
    /// as `["masks"]`, not silently missed by an array-level string
    /// comparison that happened to produce the same text.
    func testTwoMaskArraysDifferingInOneFieldAreDetected() {
        // Start from the SAME mask (same `id`, since `Mask.id` defaults to
        // a fresh `UUID()` and two independently-constructed masks would
        // always differ by id alone) and mutate only `exposureEV` on the
        // copy, so a false pass from the id difference alone is impossible.
        let mask = Mask(centerX: 0.4, centerY: 0.4, radiusX: 0.2, radiusY: 0.2, exposureEV: 0.5)
        var old = EditState.identity
        old.masks = [mask]
        var mutatedMask = mask
        mutatedMask.exposureEV = 0.9
        var new = EditState.identity
        new.masks = [mutatedMask]

        XCTAssertEqual(EditStateDiff.changedFieldNames(from: old, to: new), ["masks"])
    }

    /// The concrete case that motivates comparing with each field's own
    /// `==` rather than `String(describing:)`: `-0.0` and `0.0` print
    /// differently but are numerically `==`, so this must NOT be reported
    /// as a change.
    func testNegativeZeroIsNotADifference() {
        var old = EditState.identity
        old.exposureEV = 0.0
        var new = EditState.identity
        new.exposureEV = -0.0

        XCTAssertEqual(EditStateDiff.changedFieldNames(from: old, to: new), [])
    }

    func testChangedFieldOrderFollowsDeclarationOrder() {
        var new = EditState.identity
        new.masks = [Mask(centerX: 0.4, centerY: 0.4, radiusX: 0.2, radiusY: 0.2, exposureEV: 0.5)]
        new.exposureEV = 1.0

        let changed = EditStateDiff.changedFieldNames(from: .identity, to: new)
        // exposureEV is declared before masks in EditState.
        XCTAssertEqual(changed, ["exposureEV", "masks"])
    }

    func testSummaryWithExactlyMaxNamesHasNoMoreSuffix() {
        var new = EditState.identity
        new.exposureEV = 1.0
        new.contrast = 0.5
        new.blackAndWhite = true

        let summary = EditStateDiff.summary(from: .identity, to: new, maxNames: 3)
        XCTAssertFalse(summary.contains("more"))
        XCTAssertEqual(summary, "Exposure EV, Contrast, Black And White")
    }

    func testSummaryWithMoreThanMaxNamesAppendsCount() {
        var new = EditState.identity
        new.exposureEV = 1.0
        new.contrast = 0.5
        new.blackAndWhite = true
        new.vibrance = 0.3

        let summary = EditStateDiff.summary(from: .identity, to: new, maxNames: 3)
        // Declaration order: exposureEV, contrast, vibrance, then
        // blackAndWhite — matches EditState.swift's own field order, not
        // this test's call-site assignment order.
        XCTAssertEqual(summary, "Exposure EV, Contrast, Vibrance and 1 more")
    }

    func testDisplayNameExposureEV() {
        XCTAssertEqual(EditStateDiff.displayName(forField: "exposureEV"), "Exposure EV")
    }

    func testDisplayNameBlackPoint() {
        XCTAssertEqual(EditStateDiff.displayName(forField: "blackPoint"), "Black Point")
    }

    func testDisplayNameToneCurvePointsRed() {
        XCTAssertEqual(EditStateDiff.displayName(forField: "toneCurvePointsRed"), "Tone Curve Points Red")
    }

    func testDisplayNameRawExposureEV() {
        XCTAssertEqual(EditStateDiff.displayName(forField: "rawExposureEV"), "Raw Exposure EV")
    }

    /// The acronym-then-new-word case: an uppercase run followed by a NEW
    /// lowercase word must split ("EV" | "Bias"), unlike a trailing
    /// uppercase run with nothing after it ("exposureEV"'s own "EV",
    /// covered by `testDisplayNameExposureEV` above), which stays fused.
    /// No real `EditState` field is named this way today — this pins the
    /// general algorithm, not a specific field.
    func testDisplayNameSplitsAnAcronymFromAFollowingWord() {
        XCTAssertEqual(EditStateDiff.displayName(forField: "rawEVBias"), "Raw EV Bias")
    }

    /// A structural guard: every `EditState` stored property must surface a
    /// non-nil, non-underscore-prefixed label through `Mirror` — catches a
    /// future stored property (e.g. behind a property wrapper) silently
    /// breaking the label walk `changedFieldNames` depends on.
    func testEveryEditStateFieldHasAUsableMirrorLabel() {
        let children = Mirror(reflecting: EditState()).children
        XCTAssertFalse(children.isEmpty)
        for child in children {
            guard let label = child.label else {
                XCTFail("EditState has a stored property with no Mirror label")
                continue
            }
            XCTAssertFalse(label.hasPrefix("_"), "unexpected underscore-prefixed label: \(label)")
        }
    }

    /// Directly tests the doc-commented claim that `changedFieldNames`
    /// agrees with `EditState`'s own compiler-synthesized `==` — not just
    /// argued in a comment. Exercises one field of each of several
    /// distinct stored-property types (`Double`, `Bool`, `String`, and two
    /// different `Array` element types), which would also catch a future
    /// field whose type breaks the `as? any Equatable` cast (the
    /// `assertionFailure` fallback branch).
    func testChangedFieldNamesAgreesWithEditStateEquality() {
        var a = EditState.identity
        var b = EditState.identity
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: a, to: b).isEmpty, a == b)

        b.exposureEV = 1.0
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: a, to: b).isEmpty, a == b)
        a = b

        b.blackAndWhite = true
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: a, to: b).isEmpty, a == b)
        a = b

        b.rawDecoderVersionPin = "pinned-version"
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: a, to: b).isEmpty, a == b)
        a = b

        b.toneCurvePoints = [ToneCurvePoint(x: 0.3, y: 0.4)]
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: a, to: b).isEmpty, a == b)
        a = b

        b.masks = [Mask(centerX: 0.4, centerY: 0.4, radiusX: 0.2, radiusY: 0.2, exposureEV: 0.5)]
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: a, to: b).isEmpty, a == b)
    }
}
