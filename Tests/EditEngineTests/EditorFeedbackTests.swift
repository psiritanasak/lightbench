import XCTest
@testable import PhotoApp

/// Which Editor results are passing toasts and which are alerts. The "already in that state" texts are toasts; everything else means the
/// request was NOT applied and is an alert. Tests use the solvers' own constants.
@MainActor
final class EditorFeedbackTests: XCTestCase {
    func testTitlesAreTodaysAlertTitles() {
        XCTAssertEqual(EditorFeedbackTool.allCases.map(\.title),
                       ["Auto Straighten", "Upright", "Auto Crop", "Spot Removal", "Subject Mask", "Depth Range Mask"])
    }

    func testEveryAlreadyStateTextIsANothingToDoToast() {
        let table: [(EditorFeedbackTool, String)] = [
            (.autoStraighten, StraightenMessages.alreadyLevel), (.autoStraighten, StraightenMessages.alreadyApplied),
            (.upright, UprightMessages.alreadyUpright), (.upright, UprightMessages.alreadyApplied),
            (.autoCrop, AutoCropMessages.nothingToCrop), (.autoCrop, AutoCropMessages.alreadyApplied),
        ]
        for (tool, message) in table {
            let f = EditorFeedback.feedback(tool, message)
            XCTAssertEqual(f, Feedback(kind: .nothingToDo, title: tool.title, message: message))
            XCTAssertEqual(f.presentation, .toast)
        }
    }

    func testEveryOtherConstantIsAnAlert() {
        let table: [(EditorFeedbackTool, String)] = [
            (.autoStraighten, StraightenMessages.noHorizon), (.autoStraighten, StraightenMessages.rotatedMeanwhile),
            (.autoStraighten, "Wait for the photo to finish loading, then try again."), (.autoStraighten, "some detector failure"),
            (.upright, UprightMessages.noLines), (.upright, UprightMessages.noLevelLines), (.upright, UprightMessages.noAgreement),
            (.upright, UprightMessages.unmeasurable), (.upright, UprightMessages.tiltTooLarge), (.upright, StraightenMessages.rotatedMeanwhile),
            (.autoCrop, AutoCropMessages.tooLarge), (.autoCrop, AutoCropMessages.unmeasurable), (.autoCrop, AutoCropMessages.changedMeanwhile),
            (.spotRemoval, "No good source was found automatically — drag the dashed circle to choose one."),
            (.spotRemoval, "A photo can have at most \(EditState.maxRetouchSpots) spots."),
            (.subjectMask, "No subject was found in this photo."), (.subjectMask, "No subject at that point."),
            (.depthMask, "That mask was deleted before its depth was ready."),
            // A constant of another tool's "already" set is not a toast for this tool.
            (.upright, StraightenMessages.alreadyLevel), (.spotRemoval, StraightenMessages.alreadyLevel),
        ]
        for (tool, message) in table {
            let f = EditorFeedback.feedback(tool, message)
            XCTAssertEqual(f, Feedback(kind: .error, title: tool.title, message: message), message)
            XCTAssertEqual(f.presentation, .alert)
        }
    }

    // MARK: - ImageDocumentModel posts once per write

    func testSettingAMessagePostsOnceAndNilPostsNothing() {
        let model = ImageDocumentModel()
        model.straightenMessage = StraightenMessages.alreadyLevel
        XCTAssertEqual(model.postedFeedback, [Feedback(kind: .nothingToDo, title: "Auto Straighten", message: StraightenMessages.alreadyLevel)])
        model.straightenMessage = nil
        XCTAssertEqual(model.postedFeedback.count, 1)
        model.retouchMessage = "x"
        model.uprightMessage = UprightMessages.alreadyApplied
        model.autoCropMessage = AutoCropMessages.tooLarge
        model.subjectMaskMessage = "s"
        model.depthMaskMessage = "d"
        XCTAssertEqual(model.postedFeedback.dropFirst().map(\.kind), [.error, .nothingToDo, .error, .error, .error])
        XCTAssertEqual(model.postedFeedback.dropFirst().map(\.title),
                       ["Spot Removal", "Upright", "Auto Crop", "Subject Mask", "Depth Range Mask"])
    }

    func testTheSamePassingTextWrittenTwiceIsTwoResults() {
        let model = ImageDocumentModel()
        model.straightenMessage = StraightenMessages.alreadyLevel
        model.straightenMessage = StraightenMessages.alreadyLevel
        XCTAssertEqual(model.postedFeedback.count, 2, "a second press that finds the same thing still answers")
    }

    // MARK: - Looks

    func testLookFeedbackStatics() {
        struct Boom: LocalizedError { var errorDescription: String? { "bad cube" } }
        XCTAssertEqual(LooksTabView.importedFeedback(name: "Warm"), Feedback(kind: .done, title: "Import Look", message: "Imported \"Warm\"."))
        XCTAssertEqual(LooksTabView.importFailedFeedback(Boom()), Feedback(kind: .error, title: "Import Look", message: "bad cube"))
        XCTAssertEqual(LooksTabView.removeFailedFeedback(Boom()), Feedback(kind: .error, title: "Remove Look", message: "bad cube"))
    }
}
