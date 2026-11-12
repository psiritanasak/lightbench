import XCTest
@testable import PhotoApp

/// Kinds, titles, texts and Finder actions of the five Library tool dialogs' results (Merge, XMP, Trash, Catalog Backup, Copy Photos), and the
/// rule that a plain-string `statusMessage` is always an alert. Also pins that each dialog modifier relays through the one inbox.
@MainActor
final class ToolDialogFeedbackTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/UI/\(name).swift"), encoding: .utf8)
    }

    // MARK: Shims

    func testPlainStatusMessagesAreErrorAlertsWithTheDialogsTitle() {
        let merge = MergeModel(); merge.statusMessage = "x"
        XCTAssertEqual(merge.feedback, .error("Photo Merge", "x"))
        let xmp = XMPModel(); xmp.statusMessage = "x"
        XCTAssertEqual(xmp.feedback, .error("XMP Metadata", "x"))
        let trash = TrashModel(); trash.statusMessage = "x"
        XCTAssertEqual(trash.feedback, .error("Move to Trash", "x"))
        let backup = CatalogBackupModel(); backup.statusMessage = "x"
        XCTAssertEqual(backup.feedback, .error("Catalog Backup", "x"))
        let copy = ImportCopyModel(); copy.statusMessage = "x"
        XCTAssertEqual(copy.feedback, .error("Copy Photos", "x"))
        merge.statusMessage = nil
        XCTAssertNil(merge.feedback)
        XCTAssertNil(merge.statusMessage)
    }

    func testEachModifierRelaysItsFeedbackThroughTheCatalogQueue() throws {
        for name in ["MergeDialogModifier", "XMPDialogModifier", "TrashDialogModifier", "CatalogBackupDialogModifier", "ImportCopyDialogModifier"] {
            let text = try source(name)
            XCTAssertTrue(text.contains(".relayFeedback($model.feedback, to: catalog.post)"), name)
            XCTAssertFalse(text.contains(".alert("), name)
        }
    }

    // MARK: Merge

    private func outcome(inliers: Int = 90, correction: Float = 0, mode: MergeOutcome.Mode = .hdr) -> MergeOutcome {
        let url = URL(fileURLWithPath: "/tmp/Merged.tif")
        var o = MergeOutcome(url: url, frameCount: 3, referenceName: "mid.jpg",
                             alignment: [.init(name: "a.jpg", inlierCount: inliers, matchCount: 100)],
                             gains: [.init(name: "a.jpg", exifGain: 1, usedGain: 1 + correction)])
        o.mode = mode
        return o
    }

    func testMergeKinds() {
        let plain = MergeModel.feedback(for: outcome())
        XCTAssertEqual(plain.kind, .done)
        XCTAssertEqual(plain.title, "Photo Merge")
        XCTAssertEqual(plain.message, "Created “Merged.tif” from 3 photos (exposure reference: mid.jpg), aligned.")
        XCTAssertEqual(plain.action, .revealInFinder([URL(fileURLWithPath: "/tmp/Merged.tif")]))

        let uncertain = MergeModel.feedback(for: outcome(inliers: 30))
        XCTAssertEqual(uncertain.kind, .notice)
        XCTAssertTrue(uncertain.message.contains("uncertain"))
        XCTAssertEqual(MergeModel.feedback(for: outcome(inliers: 30, mode: .panorama)).kind, .notice)

        let corrected = MergeModel.feedback(for: outcome(correction: 0.2))
        XCTAssertEqual(corrected.kind, .notice)
        XCTAssertTrue(corrected.message.contains("was corrected"))
        XCTAssertEqual(MergeModel.feedback(for: outcome(inliers: 50, correction: 0.04)).kind, .done, "exactly half agreed and a 4% gap add no sentence")
    }

    func testMergeNotRegisteredIsIncompleteWithTheAction() {
        let f = MergeModel.notRegisteredFeedback(outcome(), reason: "disk full")
        XCTAssertEqual(f.kind, .incomplete)
        XCTAssertEqual(f.message, "Created “Merged.tif”, but couldn't add it to the Library: disk full")
        XCTAssertEqual(f.action, .revealInFinder([URL(fileURLWithPath: "/tmp/Merged.tif")]))
    }

    // MARK: XMP

    func testXMPWriteKinds() {
        func kind(_ edit: (inout XMPModel.Result) -> Void) -> FeedbackKind {
            var r = XMPModel.Result(kind: .write); edit(&r); return XMPModel.feedback(for: r).kind
        }
        XCTAssertEqual(kind { $0.changed = 3 }, .done)
        XCTAssertEqual(kind { _ in }, .nothingToDo)
        XCTAssertEqual(kind { $0.changed = 3; $0.sharedWithRaw = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.changed = 3; $0.unreadable = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.changed = 3; $0.failed = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.noAccess = 2 }, .incomplete)
        var r = XMPModel.Result(kind: .write); r.changed = 2
        XCTAssertEqual(XMPModel.feedback(for: r).message, "Wrote XMP for 2 photos.")
        XCTAssertEqual(XMPModel.feedback(for: r).title, "XMP Metadata")
    }

    func testXMPReadKindsANoXMPPhotoIsAWarningToast() {
        func kind(_ edit: (inout XMPModel.Result) -> Void) -> FeedbackKind {
            var r = XMPModel.Result(kind: .read); edit(&r); return XMPModel.feedback(for: r).kind
        }
        XCTAssertEqual(kind { $0.changed = 2 }, .done)
        XCTAssertEqual(kind { $0.unchanged = 2 }, .nothingToDo)
        XCTAssertEqual(kind { $0.changed = 2; $0.noXMP = 1 }, .warning)
        XCTAssertEqual(kind { $0.noXMP = 3 }, .warning)
        XCTAssertEqual(kind { $0.changed = 2; $0.noXMP = 1; $0.unreadable = 1 }, .incomplete, "an unparseable .xmp is still an alert")
        XCTAssertEqual(kind { $0.changed = 2; $0.noAccess = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.noXMP = 1; $0.noAccess = 1 }, .incomplete)
        var r = XMPModel.Result(kind: .read); r.unchanged = 2
        XCTAssertEqual(XMPModel.feedback(for: r).message, "The Library already matched the XMP data.")
    }

    // MARK: Trash

    func testTrashKinds() {
        func kind(_ edit: (inout TrashModel.Result) -> Void) -> FeedbackKind {
            var r = TrashModel.Result(); edit(&r); return TrashModel.feedback(for: r).kind
        }
        XCTAssertEqual(kind { $0.trashed = 2; $0.companions = 3 }, .done)
        XCTAssertEqual(kind { _ in }, .nothingToDo)
        XCTAssertEqual(kind { $0.trashed = 2; $0.skipped = [.init(photoID: 1, name: "a", reason: .openInEditor)] }, .incomplete)
        XCTAssertEqual(kind { $0.trashed = 2; $0.lateSkippedOpen = ["a.jpg"] }, .incomplete)
        XCTAssertEqual(kind { $0.trashed = 2; $0.stoppedBecause = "x" }, .incomplete)
        XCTAssertEqual(kind { $0.trashed = 2; $0.notAttempted = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.noLongerRejected = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.noAccess = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.trashed = 2; $0.failed = [.init(photoID: 1, name: "a", message: "m")] }, .incomplete)
        XCTAssertEqual(kind { $0.trashed = 2; $0.companionsFailed = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.trashed = 2; $0.catalogError = "db" }, .incomplete)
        var r = TrashModel.Result(); r.trashed = 2; r.companions = 1
        let f = TrashModel.feedback(for: r)
        XCTAssertEqual(f.message, "Moved 2 photos to the Trash with 1 edit / XMP file.")
        XCTAssertEqual(f.title, "Move to Trash")
        XCTAssertNil(f.action)
    }

    // MARK: Catalog backup

    func testBackupAndStagedRestoreAreNoticesAndBackupRevealsTheFile() {
        let url = URL(fileURLWithPath: "/tmp/Cat.sqlite")
        let backed = CatalogBackupModel.backedUpFeedback(photoCount: 5, destination: url)
        XCTAssertEqual(backed.kind, .notice)
        XCTAssertEqual(backed.title, "Catalog Backup")
        XCTAssertEqual(backed.message, CatalogBackupModel.backedUpMessage(photoCount: 5, fileName: "Cat.sqlite"))
        XCTAssertEqual(backed.action, .revealInFinder([url]))
        let staged = CatalogBackupModel.stagedFeedback(photoCount: 5)
        XCTAssertEqual(staged.kind, .notice)
        XCTAssertEqual(staged.message, CatalogBackupModel.stagedMessage(photoCount: 5))
        XCTAssertNil(staged.action)
    }

    // MARK: Copy Photos

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/dest/\(name)") }

    func testCopyModeKinds() {
        func kind(_ edit: (inout ImportCopyEngine.Outcome) -> Void, registered: ImportCopyModel.Registration? = .init(added: 2, accessWarning: nil, error: nil),
                  mode: ImportCopyOptions.Mode = .copy) -> FeedbackKind {
            var o = ImportCopyEngine.Outcome(); edit(&o); return ImportCopyModel.feedback(o, registered: registered, mode: mode).kind
        }
        let src = url("src.jpg")
        let fail = ImportCopyEngine.Failure(source: src, reason: "r")
        XCTAssertEqual(kind { $0.copied = [url("a"), url("b")] }, .done)
        XCTAssertEqual(kind({ $0.skippedIdentical = [src]; $0.skippedDestinations = [src] }, registered: .init(added: 0, accessWarning: nil, error: nil)), .nothingToDo)
        XCTAssertEqual(kind { $0.copied = [url("a")]; $0.failed = [fail] }, .incomplete)
        XCTAssertEqual(kind { $0.copied = [url("a")]; $0.blocked = [fail] }, .incomplete)
        XCTAssertEqual(kind { $0.copied = [url("a")]; $0.companionFailures = [fail] }, .incomplete)
        XCTAssertEqual(kind { $0.copied = [url("a")]; $0.stoppedEarly = true }, .incomplete)
        XCTAssertEqual(kind({ $0.copied = [url("a")] }, registered: .init(added: 0, accessWarning: nil, error: "e")), .incomplete)
        XCTAssertEqual(kind({ $0.copied = [url("a")] }, registered: .init(added: 1, accessWarning: "w", error: nil)), .incomplete)
        XCTAssertEqual(kind({ _ in }, registered: nil), .nothingToDo)
        XCTAssertEqual(kind({ $0.blocked = [fail] }, registered: nil), .incomplete)
    }

    func testMoveModeIsNeverAToast() {
        func kind(_ edit: (inout ImportCopyEngine.Outcome) -> Void) -> FeedbackKind {
            var o = ImportCopyEngine.Outcome(); edit(&o)
            return ImportCopyModel.feedback(o, registered: .init(added: 1, accessWarning: nil, error: nil), mode: .move).kind
        }
        let fail = ImportCopyEngine.Failure(source: url("s"), reason: "r")
        XCTAssertEqual(kind { $0.copied = [url("a")]; $0.movedToTrash = [url("s")] }, .notice)
        XCTAssertEqual(kind { _ in }, .notice)
        XCTAssertEqual(kind { $0.copied = [url("a")]; $0.notMoved = [fail] }, .incomplete)
        XCTAssertEqual(kind { $0.copied = [url("a")]; $0.companionsNotTrashed = 1 }, .incomplete)
        XCTAssertEqual(kind { $0.copied = [url("a")]; $0.failed = [fail] }, .incomplete)
    }

    func testCopyTextActionAndTitle() {
        var o = ImportCopyEngine.Outcome(); o.copied = [url("a.jpg"), url("b.jpg")]
        let reg = ImportCopyModel.Registration(added: 2, accessWarning: nil, error: nil)
        let f = ImportCopyModel.feedback(o, registered: reg)
        XCTAssertEqual(f.title, "Copy Photos")
        XCTAssertEqual(f.message, ImportCopyModel.summary(o, registered: reg, mode: .copy))
        XCTAssertEqual(f.message, "Copied 2 photos and checked each copy against the original.\nAdded 2 photos to the Library.\nYour original photos were not changed.")
        XCTAssertEqual(f.action, .revealInFinder([url("a.jpg"), url("b.jpg")]))
        XCTAssertNil(ImportCopyModel.feedback(ImportCopyEngine.Outcome(), registered: nil).action, "nothing copied: nothing to reveal")
    }
}
