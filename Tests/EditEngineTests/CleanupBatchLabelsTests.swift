import XCTest
@testable import PhotoApp

/// Cleanup batch C: the pure helpers behind the Curve channel caption (D21) and the empty-Subject-mask notice (D44).
final class CleanupBatchLabelsTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])

    // MARK: D21

    func testSegmentLabelsAreAlwaysPlain() {
        for channel in ToneCurveChannel.allCases {
            XCTAssertEqual(ToneCurveChannelLabels.segmentLabel(for: channel), channel.rawValue)
            XCTAssertFalse(ToneCurveChannelLabels.segmentLabel(for: channel).contains("•"))
        }
    }

    func testEditedCaptionNamesEditedChannelsInPickerOrder() {
        XCTAssertNil(ToneCurveChannelLabels.editedCaption(editedChannels: []))
        XCTAssertEqual(ToneCurveChannelLabels.editedCaption(editedChannels: [.blue, .red]), "Edited: Red, Blue")
        XCTAssertEqual(ToneCurveChannelLabels.editedCaption(editedChannels: [.red]), "Edited: Red")
        XCTAssertEqual(
            ToneCurveChannelLabels.editedCaption(editedChannels: Set(ToneCurveChannel.allCases)),
            "Edited: RGB, Red, Green, Blue"
        )
    }

    func testCaptionRowIsNeverEmptySoTheCanvasDoesNotMove() {
        XCTAssertEqual(ToneCurveChannelLabels.captionRowText(editedChannels: []), " ")
        XCTAssertEqual(ToneCurveChannelLabels.captionRowText(editedChannels: [.red]), "Edited: Red")
    }

    // MARK: D44

    func testAllSubjectsUntickedSelectsNothing() {
        let mask = Mask(kind: .subject, subjectInstancePNGs: [png, png], subjectInstanceEnabled: [false, false])
        XCTAssertTrue(SubjectSelectionState.selectsNothing(mask))
        var inverted = mask
        inverted.invertSelection = true
        XCTAssertTrue(SubjectSelectionState.selectsNothing(inverted))
    }

    func testInvertStaysEnabledWhenAlreadyOn() {
        var mask = Mask(kind: .subject, subjectInstancePNGs: [png, png], subjectInstanceEnabled: [false, false])
        XCTAssertTrue(SubjectSelectionState.invertIsDisabled(mask))
        mask.invertSelection = true
        XCTAssertFalse(SubjectSelectionState.invertIsDisabled(mask), "must be able to turn Invert off")
        XCTAssertFalse(SubjectSelectionState.invertIsDisabled(Mask(kind: .subject, subjectMaskPNG: png)))
    }

    func testAnyTickedOrLegacyOrUnstoredSubjectDoesNotTrigger() {
        XCTAssertFalse(SubjectSelectionState.selectsNothing(
            Mask(kind: .subject, subjectInstancePNGs: [png, png], subjectInstanceEnabled: [false, true])
        ))
        // Missing flags mean "enabled".
        XCTAssertFalse(SubjectSelectionState.selectsNothing(Mask(kind: .subject, subjectInstancePNGs: [png, png])))
        // A legacy single raster.
        XCTAssertFalse(SubjectSelectionState.selectsNothing(Mask(kind: .subject, subjectMaskPNG: png)))
        // Nothing stored at all has its own "No subject stored" text.
        XCTAssertFalse(SubjectSelectionState.selectsNothing(Mask(kind: .subject)))
    }
}
