import XCTest
@testable import PhotoApp

final class SidecarSaveStatusPresentationTests: XCTestCase {
    private let fileName = "a.png.photoapp.json"

    private func make(_ status: SidecarSaveStatus) -> SidecarSaveStatusPresentation? {
        SidecarSaveStatusPresentation.make(for: status, sidecarFileName: fileName)
    }

    func testOkShowsNothing() { XCTAssertNil(make(.ok)) }

    func testEveryProblemSharesTheTitleAndHasHelp() {
        for status in [SidecarSaveStatus.refusedNotLoaded, .refusedUnreadable, .folderDeclined, .writeFailed("disk full")] {
            let p = make(status)
            XCTAssertEqual(p?.title, "Edits not saved", "\(status)")
            XCTAssertFalse(p?.help.isEmpty ?? true, "\(status)")
            XCTAssertFalse(p?.actionTitle.isEmpty ?? true, "\(status)")
        }
    }

    func testEachStateOffersItsOwnAction() {
        XCTAssertEqual(make(.refusedNotLoaded)?.action, .reload)
        XCTAssertEqual(make(.refusedUnreadable)?.action, .showInFinder)
        XCTAssertEqual(make(.folderDeclined)?.action, .grantAccess)
        XCTAssertEqual(make(.writeFailed("x"))?.action, .tryAgain)
    }

    func testActionTitles() {
        XCTAssertEqual(make(.refusedNotLoaded)?.actionTitle, "Reload")
        XCTAssertEqual(make(.refusedUnreadable)?.actionTitle, "Show in Finder")
        XCTAssertEqual(make(.folderDeclined)?.actionTitle, "Grant Access…")
        XCTAssertEqual(make(.writeFailed("x"))?.actionTitle, "Try Again")
    }

    func testHelpNamesTheEditFileWhereItMatters() {
        XCTAssertTrue(make(.refusedNotLoaded)?.help.contains(fileName) == true)
        XCTAssertTrue(make(.refusedUnreadable)?.help.contains(fileName) == true)
    }

    func testTheWriteFailureHelpCarriesTheReason() {
        XCTAssertTrue(make(.writeFailed("The disk is full."))?.help.contains("The disk is full.") == true)
    }

    func testTheDeclinedHelpMentionsTheFolder() {
        XCTAssertTrue(make(.folderDeclined)?.help.lowercased().contains("folder") == true)
    }

    func testStatusEquality() {
        XCTAssertEqual(SidecarSaveStatus.writeFailed("a"), .writeFailed("a"))
        XCTAssertNotEqual(SidecarSaveStatus.writeFailed("a"), .writeFailed("b"))
        XCTAssertNotEqual(SidecarSaveStatus.ok, .folderDeclined)
    }

    func testOnlyTheReloadActionIsDestructive() {
        XCTAssertTrue(SidecarSaveStatusPresentation.Action.reload.discardsEdits)
        for action in [SidecarSaveStatusPresentation.Action.showInFinder, .grantAccess, .tryAgain] {
            XCTAssertFalse(action.discardsEdits)
        }
    }
}
