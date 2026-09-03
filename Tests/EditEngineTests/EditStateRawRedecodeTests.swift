import XCTest
@testable import PhotoApp

/// Verifies `EditState.requiresRawRedecode(comparedTo:)` — Phase 6 slice 2's
/// single source of truth for "does this field change require a full RAW
/// re-decode, not just an `EditPipeline` re-run." `ImageDocumentModel`'s
/// `editState` `didSet` is the only caller; a false negative here would mean
/// a RAW-native field change silently has no visible effect (the exact bug
/// `RawDecoder.materialize`'s "forward hazard" note predicted), and a false
/// positive would mean an unrelated slider edit pays a needless multi-second
/// re-decode.
final class EditStateRawRedecodeTests: XCTestCase {
    func testTrueWhenBoostAmountDiffers() {
        var a = EditState.identity
        var b = EditState.identity
        a.boostAmount = 0.2
        b.boostAmount = 0.8
        XCTAssertTrue(a.requiresRawRedecode(comparedTo: b))
    }

    func testFalseWhenBoostAmountIsTheSame() {
        var a = EditState.identity
        var b = EditState.identity
        a.boostAmount = 0.5
        b.boostAmount = 0.5
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

    func testFalseComparedToItself() {
        var a = EditState.identity
        a.boostAmount = 0.6
        XCTAssertFalse(a.requiresRawRedecode(comparedTo: a))
    }
}
