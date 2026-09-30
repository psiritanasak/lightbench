import XCTest
@testable import PhotoApp

final class RenamePlanTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_772_719_629)

    private func photo(_ id: Int64?, _ path: String, rating: Int = 0) -> Photo {
        Photo(id: id, path: path, filename: URL(fileURLWithPath: path).lastPathComponent, fileSize: nil,
              importedAt: date, rating: rating)
    }

    private func env(
        files: Set<String>, catalog: [String: Int64] = [:], open: String? = nil
    ) -> RenameEnvironment {
        RenameEnvironment(
            fileExists: { files.contains($0) }, catalogPhotoID: { catalog[$0] }, openPhotoPath: open
        )
    }

    private func plan(
        _ photos: [Photo], template: String, start: Int = 1, files: Set<String>? = nil,
        catalog: [String: Int64] = [:], open: String? = nil
    ) throws -> RenamePlan {
        let compiled = try NamingTemplate.compile(template).get()
        return RenamePlan.make(
            photos: photos, template: compiled, sequenceStart: start, captureDates: [:],
            environment: env(files: files ?? Set(photos.map(\.path)), catalog: catalog, open: open)
        )
    }

    private func blocks(_ plan: RenamePlan) -> [RenameBlock?] {
        plan.entries.map { if case .blocked(let block) = $0.decision { return block } else { return nil } }
    }

    // MARK: Basics

    func testRendersNamesInTheGivenOrderIntoTheSameFolder() throws {
        let p = try plan([photo(1, "/f/a.jpg"), photo(2, "/f/b.JPG")], template: "Trip_{seq}")
        XCTAssertEqual(p.renames, [
            RenameMove(photoID: 1, oldPath: "/f/a.jpg", newPath: "/f/Trip_001.jpg"),
            RenameMove(photoID: 2, oldPath: "/f/b.JPG", newPath: "/f/Trip_002.JPG") // extension case kept
        ])
        XCTAssertTrue(p.isApplicable)
    }

    func testSequenceStartIsHonoured() throws {
        let p = try plan([photo(1, "/f/a.jpg"), photo(2, "/f/b.jpg")], template: "{seq}", start: 40)
        XCTAssertEqual(p.renames.map(\.newPath), ["/f/040.jpg", "/f/041.jpg"])
    }

    func testAnIdentityTemplateChangesNothingAndIsNotApplicable() throws {
        let p = try plan([photo(1, "/f/a.jpg"), photo(2, "/f/b.jpg")], template: "{name}")
        XCTAssertEqual(p.entries.map(\.decision), [.unchanged, .unchanged])
        XCTAssertTrue(p.renames.isEmpty)
        XCTAssertFalse(p.isApplicable)
    }

    func testANameThatOnlyDiffersByUnicodeNormalizationIsUnchanged() throws {
        let nfd = "/f/caf\u{65}\u{301}.jpg"
        let p = try plan([photo(1, nfd)], template: "caf\u{e9}")
        XCTAssertEqual(p.entries.first?.decision, .unchanged)
    }

    func testTheSameNameInDifferentFoldersIsNotACollision() throws {
        let p = try plan([photo(1, "/a/x.jpg"), photo(2, "/b/y.jpg")], template: "same")
        XCTAssertTrue(p.isApplicable)
        XCTAssertEqual(p.renames.map(\.newPath), ["/a/same.jpg", "/b/same.jpg"])
    }

    // MARK: Collisions inside the batch

    func testTwoPhotosGettingTheSameNameAreBothBlocked() throws {
        let p = try plan([photo(1, "/f/a.jpg"), photo(2, "/f/b.jpg")], template: "same")
        XCTAssertEqual(blocks(p), [.collidesWithBatch("b.jpg"), .collidesWithBatch("a.jpg")])
        XCTAssertFalse(p.isApplicable)
    }

    /// Two files that differ only by case ("Pic.jpg"/"pic.jpg" can coexist on a case-sensitive
    /// volume) are the same name on default APFS — the plan must treat them as colliding.
    func testNamesDifferingOnlyByCaseCollide() throws {
        let p = try plan([photo(1, "/f/Pic.jpg"), photo(2, "/f/pic.jpg")], template: "{name}")
        XCTAssertEqual(blocks(p), [.collidesWithBatch("pic.jpg"), .collidesWithBatch("Pic.jpg")])
        XCTAssertEqual(RenamePlan.key(forFileName: "Pic.JPG"), RenamePlan.key(forFileName: "pic.jpg"))
        XCTAssertEqual(RenamePlan.key(forFileName: "caf\u{e9}.jpg"), RenamePlan.key(forFileName: "cafe\u{301}.jpg"))
    }

    func testAPhotoThatKeepsItsNameBlocksAnotherPhotoWantingIt() throws {
        // r1.jpg keeps its name (rating 1 -> "r1"); other.jpg (rating 1) would also become "r1.jpg".
        let p = try plan([photo(1, "/f/r1.jpg", rating: 1), photo(2, "/f/other.jpg", rating: 1)], template: "r{rating}")
        XCTAssertEqual(blocks(p), [.collidesWithBatch("other.jpg"), .collidesWithBatch("r1.jpg")])
    }

    // MARK: Chains, swaps, case-only renames

    func testAChainWhereOneTargetIsAnotherSourcesOldNameIsLegal() throws {
        // 002.jpg -> 001.jpg, 003.jpg -> 002.jpg (002 is vacated by the first rename).
        let p = try plan([photo(1, "/f/002.jpg"), photo(2, "/f/003.jpg")], template: "{seq}")
        XCTAssertTrue(p.isApplicable, "\(blocks(p))")
        XCTAssertEqual(p.renames.map(\.newPath), ["/f/001.jpg", "/f/002.jpg"])
    }

    func testASwapIsLegal() throws {
        let p = try plan([photo(1, "/f/002.jpg"), photo(2, "/f/001.jpg")], template: "{seq}")
        XCTAssertTrue(p.isApplicable, "\(blocks(p))")
        XCTAssertEqual(p.renames.map(\.newPath), ["/f/001.jpg", "/f/002.jpg"])
    }

    func testACaseOnlyRenameIsLegalEvenThoughTheFileSystemSaysTheTargetExists() throws {
        // On a case-insensitive volume "/f/img.jpg" "exists" — it's the same file.
        let p = try plan([photo(1, "/f/IMG.jpg")], template: "img", files: ["/f/IMG.jpg", "/f/img.jpg"])
        XCTAssertTrue(p.isApplicable, "\(blocks(p))")
        XCTAssertEqual(p.renames, [RenameMove(photoID: 1, oldPath: "/f/IMG.jpg", newPath: "/f/img.jpg")])
    }

    // MARK: Collisions with the outside world

    func testAnExistingFileOutsideTheBatchBlocks() throws {
        let p = try plan([photo(1, "/f/a.jpg")], template: "taken", files: ["/f/a.jpg", "/f/taken.jpg"])
        XCTAssertEqual(blocks(p), [.targetExists])
    }

    func testAnExistingSidecarAtTheTargetBlocksEvenWithoutAPhoto() throws {
        let p = try plan([photo(1, "/f/a.jpg")], template: "new",
                         files: ["/f/a.jpg", "/f/new.jpg.photoapp.json"]) // orphaned sidecar
        XCTAssertEqual(blocks(p), [.targetSidecarExists])
    }

    func testASidecarBeingVacatedByTheBatchDoesNotBlock() throws {
        // 002.jpg (with a sidecar) is renamed away to 001.jpg by the first photo's chain.
        let p = try plan(
            [photo(1, "/f/002.jpg"), photo(2, "/f/003.jpg")], template: "{seq}",
            files: ["/f/002.jpg", "/f/003.jpg", "/f/002.jpg.photoapp.json"]
        )
        XCTAssertTrue(p.isApplicable, "\(blocks(p))")
    }

    func testAnotherCataloguedPhotoAtTheTargetPathBlocksEvenIfItsFileIsGone() throws {
        let p = try plan([photo(1, "/f/a.jpg")], template: "new", files: ["/f/a.jpg"], catalog: ["/f/new.jpg": 99])
        XCTAssertEqual(blocks(p), [.targetCatalogued])
    }

    func testACataloguedPhotoInsideTheBatchThatIsRenamingAwayDoesNotBlock() throws {
        // Photo 2 owns /f/001.jpg in the catalog but is renamed away to 002; photo 1 moves INTO 001.
        let p = try plan(
            [photo(1, "/f/005.jpg"), photo(2, "/f/001.jpg")], template: "{seq}",
            catalog: ["/f/001.jpg": 2]
        )
        XCTAssertTrue(p.isApplicable, "\(blocks(p))")
        XCTAssertEqual(p.renames.map(\.newPath), ["/f/001.jpg", "/f/002.jpg"])
    }

    // MARK: Source / Editor / template problems

    func testAMissingSourceBlocks() throws {
        let p = try plan([photo(1, "/f/a.jpg")], template: "new", files: [])
        XCTAssertEqual(blocks(p), [.sourceMissing])
    }

    func testAPhotoOpenInTheEditorBlocks() throws {
        let p = try plan([photo(1, "/f/a.jpg"), photo(2, "/f/b.jpg")], template: "{seq}", open: "/f/b.jpg")
        XCTAssertEqual(blocks(p), [nil, .openInEditor])
        XCTAssertFalse(p.isApplicable) // all-or-nothing
    }

    func testTheSamePhotoSelectedTwiceIsBlocked() throws {
        let a = photo(1, "/f/a.jpg")
        let p = try plan([a, a, photo(2, "/f/b.jpg")], template: "{seq}")
        XCTAssertEqual(blocks(p), [nil, .selectedTwice, nil])
        XCTAssertFalse(p.isApplicable)
    }

    func testAnUncataloguedPhotoBlocks() throws {
        let p = try plan([photo(nil, "/f/a.jpg")], template: "new")
        XCTAssertEqual(blocks(p), [.notCatalogued])
    }

    func testATemplateThatCannotRenderBlocksThatPhoto() throws {
        // {label} is empty for every photo here -> empty result.
        let p = try plan([photo(1, "/f/a.jpg")], template: "{label}")
        XCTAssertEqual(blocks(p), [.template(.emptyResult)])
    }

    func testOneBlockedPhotoMakesTheWholePlanInapplicable() throws {
        let p = try plan([photo(1, "/f/a.jpg"), photo(2, "/f/b.jpg")], template: "n{seq}", files: ["/f/a.jpg"]) // b missing
        XCTAssertEqual(blocks(p), [nil, .sourceMissing])
        XCTAssertTrue(p.hasBlocked)
        XCTAssertFalse(p.isApplicable)
    }

    func testEveryBlockHasAHumanReadableMessage() {
        let all: [RenameBlock] = [.notCatalogued, .selectedTwice, .template(.emptyResult), .collidesWithBatch("x.jpg"), .targetExists,
                                  .targetSidecarExists, .targetCatalogued, .sourceMissing, .openInEditor]
        for block in all { XCTAssertFalse(block.message.isEmpty) }
        XCTAssertTrue(RenameBlock.collidesWithBatch("x.jpg").message.contains("x.jpg"))
    }
}
