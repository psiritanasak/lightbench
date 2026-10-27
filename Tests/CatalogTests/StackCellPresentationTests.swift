import XCTest
@testable import PhotoApp

/// The grid cell's identity and presentation per stack role (pure): the live check showed stale badges and captions when a photo changed
/// between a plain cell, a collapsed stack and an expanded member.
final class StackCellPresentationTests: XCTestCase {
    private func photo(_ id: Int64) -> Photo {
        Photo(id: id, path: "/p/\(id).jpg", filename: "\(id).jpg", fileSize: 1, importedAt: Date(timeIntervalSince1970: 0), rating: 0)
    }

    private func plain(_ id: Int64) -> StackGridItem {
        StackGridItem(photo: photo(id), role: .plain, stackID: nil, visibleMembers: [], hiddenMemberCount: 0, isCover: false)
    }

    private func collapsed(cover: Int64, members: [Int64], stack: Int64 = 1) -> StackGridItem {
        StackGridItem(photo: photo(cover), role: .collapsedStack, stackID: stack, visibleMembers: members.map(photo),
                      hiddenMemberCount: members.count - 1, isCover: true)
    }

    private func expanded(_ id: Int64, members: [Int64], cover: Int64, stack: Int64 = 1) -> StackGridItem {
        StackGridItem(photo: photo(id), role: .expandedMember, stackID: stack, visibleMembers: members.map(photo),
                      hiddenMemberCount: 0, isCover: id == cover)
    }

    // MARK: Cell identity

    func testTheCellIDChangesWhenThePhotoChangesRole() {
        let ids = [plain(1).cellID, collapsed(cover: 1, members: [1, 2]).cellID, expanded(1, members: [1, 2], cover: 1).cellID]
        XCTAssertEqual(Set(ids).count, 3, "plain, collapsed cover and expanded cover of the SAME photo are three different cells: \(ids)")
    }

    func testTheCellIDChangesWithTheStackSizeAndCover() {
        XCTAssertNotEqual(collapsed(cover: 1, members: [1, 2]).cellID, collapsed(cover: 1, members: [1, 2, 3]).cellID, "the count badge changes")
        XCTAssertNotEqual(expanded(2, members: [1, 2], cover: 1).cellID, expanded(2, members: [1, 2], cover: 2).cellID, "the cover marker moves")
        XCTAssertNotEqual(collapsed(cover: 1, members: [1, 2], stack: 1).cellID, collapsed(cover: 1, members: [1, 2], stack: 2).cellID)
    }

    func testTheCellIDIsStableForUnchangedInput() {
        XCTAssertEqual(collapsed(cover: 1, members: [1, 2]).cellID, collapsed(cover: 1, members: [1, 2]).cellID)
    }

    func testEveryCellOfOneGridHasADistinctID() {
        let items = [plain(1), collapsed(cover: 2, members: [2, 3]), plain(4)]
        XCTAssertEqual(Set(items.map(\.cellID)).count, 3)
        let open = [plain(1), expanded(2, members: [2, 3], cover: 2), expanded(3, members: [2, 3], cover: 2)]
        XCTAssertEqual(Set(open.map(\.cellID)).count, 3)
    }

    // MARK: Scroll-to

    func testScrollTargetIsTheCellIDForPlainCollapsedCoverAndExpandedMember() {
        let items = [plain(1), collapsed(cover: 2, members: [2, 3]), expanded(5, members: [5, 6], cover: 5), expanded(6, members: [5, 6], cover: 5)]
        XCTAssertEqual(StackCellPresentation.scrollTarget(forFocusedKey: "/p/1.jpg", in: items), items[0].cellID)
        XCTAssertEqual(StackCellPresentation.scrollTarget(forFocusedKey: "/p/2.jpg", in: items), items[1].cellID)
        XCTAssertEqual(StackCellPresentation.scrollTarget(forFocusedKey: "/p/6.jpg", in: items), items[3].cellID)
    }

    func testScrollTargetOfAHiddenMemberIsItsStacksCell() {
        let items = [plain(1), collapsed(cover: 2, members: [2, 3, 4])]
        XCTAssertEqual(StackCellPresentation.scrollTarget(forFocusedKey: "/p/4.jpg", in: items), items[1].cellID)
    }

    func testScrollTargetIsNilWithoutAFocusOrAKnownPhoto() {
        let items = [plain(1)]
        XCTAssertNil(StackCellPresentation.scrollTarget(forFocusedKey: nil, in: items))
        XCTAssertNil(StackCellPresentation.scrollTarget(forFocusedKey: "/elsewhere.jpg", in: items))
    }

    // MARK: Badge and caption per role

    func testACollapsedStackShowsItsCountAndASizedCaption() {
        let item = collapsed(cover: 1, members: [1, 2, 3])
        XCTAssertEqual(StackCellPresentation.badge(for: item), .count(3))
        XCTAssertEqual(StackCellPresentation.caption(name: "a.jpg", item: item), "a.jpg · 3 photos")
    }

    func testEveryExpandedMemberCoverIncludedShowsTheMarkerAndAPlainCaption() {
        for item in [expanded(1, members: [1, 2], cover: 1), expanded(2, members: [1, 2], cover: 1)] {
            XCTAssertEqual(StackCellPresentation.badge(for: item), .marker, "no collapsed-style count on an expanded cover")
            XCTAssertEqual(StackCellPresentation.caption(name: "a.jpg", item: item), "a.jpg")
        }
        XCTAssertEqual(StackCellPresentation.badgeAccessibilityLabel(for: expanded(1, members: [1, 2], cover: 1)), "Stack cover, collapse")
        XCTAssertEqual(StackCellPresentation.badgeAccessibilityLabel(for: expanded(2, members: [1, 2], cover: 1)), "Stack member, collapse")
    }

    func testAPlainCellHasNoBadgeAndAPlainCaption() {
        XCTAssertEqual(StackCellPresentation.badge(for: plain(1)), .none)
        XCTAssertEqual(StackCellPresentation.caption(name: "a.jpg", item: plain(1)), "a.jpg")
    }
}

/// The same rule on real grid items after Apply / Unstack (the live check's two stale-cell cases).
@MainActor
final class StackCellIdentityModelTests: XCTestCase {
    func testAnUnstackedCoverGetsANewCellIDAndALoneCollapsedBadgeIsGone() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...3).map { URL(fileURLWithPath: "/tmp/cid/c\($0).jpg") })
        let ids = try await db.allPhotos().compactMap(\.id)
        _ = try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true, cover: ids[0])
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: "StackCellIdentity-\(UUID().uuidString)")!)
        await model.refresh()
        let before = try XCTUnwrap(model.gridPhotos.first { $0.photo.id == ids[0] })
        XCTAssertEqual(StackCellPresentation.badge(for: before), .count(2))
        model.select([ids[0], ids[1]])
        await model.unstackSelected()
        let after = try XCTUnwrap(model.gridPhotos.first { $0.photo.id == ids[0] })
        XCTAssertEqual(StackCellPresentation.badge(for: after), .none)
        XCTAssertNotEqual(before.cellID, after.cellID, "the grid rebuilds the cell: no stale '2' badge")
    }

    func testAPhotoThatBecomesACoverGetsANewCellID() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...3).map { URL(fileURLWithPath: "/tmp/cid/d\($0).jpg") })
        let ids = try await db.allPhotos().compactMap(\.id)
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: "StackCellIdentity-\(UUID().uuidString)")!)
        await model.refresh()
        let before = try XCTUnwrap(model.gridPhotos.first { $0.photo.id == ids[0] })
        model.select([ids[0], ids[1]])
        await model.stackSelected()
        let after = try XCTUnwrap(model.gridPhotos.first { $0.photo.id == ids[0] })
        XCTAssertEqual(after.role, .collapsedStack)
        XCTAssertNotEqual(before.cellID, after.cellID, "the new stack's cover is a new cell: the badge shows at once")
    }
}
