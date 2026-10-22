import XCTest
@testable import PhotoApp

final class StackDisplayTests: XCTestCase {
    private func photo(_ id: Int64, master: Int64? = nil) -> Photo {
        Photo(id: id, path: "/p/\(master ?? id).jpg", filename: "\(id).jpg", fileSize: 1, importedAt: Date(timeIntervalSince1970: Double(id)),
              masterId: master, versionKey: master == nil ? nil : "k\(id)", versionName: master == nil ? nil : "Copy 1")
    }

    private func stack(_ id: Int64, _ members: [Int64], cover: Int64? = nil, manual: Bool = false) -> StackSnapshot {
        StackSnapshot(id: id, isManual: manual, coverPhotoID: cover, memberIDs: members.sorted())
    }

    private func ids(_ items: [StackGridItem]) -> [Int64] { items.compactMap(\.photo.id) }

    func testNoStacksIsThePlainList() {
        let items = StackDisplay.apply(displayed: [photo(1), photo(2)], stacks: [], expandedIDs: [])
        XCTAssertEqual(ids(items), [1, 2])
        XCTAssertTrue(items.allSatisfy { $0.role == .plain && $0.stackID == nil })
    }

    func testCollapsedStackIsOneCellAtTheFirstMemberPosition() {
        let displayed = [photo(1), photo(2), photo(3), photo(4), photo(5)]
        let items = StackDisplay.apply(displayed: displayed, stacks: [stack(10, [2, 4, 5], cover: 4)], expandedIDs: [])
        XCTAssertEqual(ids(items), [1, 4, 3]) // the cell sits where 2 was, shows the cover 4; 5 is hidden
        let cell = items[1]
        XCTAssertEqual(cell.role, .collapsedStack)
        XCTAssertEqual(cell.stackID, 10)
        XCTAssertEqual(cell.hiddenMemberCount, 2)
        XCTAssertEqual(cell.visibleMembers.compactMap(\.id), [2, 4, 5])
        XCTAssertFalse(cell.isExpanded)
        XCTAssertEqual(cell.id, "s10")
    }

    func testExpandedStackShowsMembersInARunAtTheFirstPosition() {
        let displayed = [photo(1), photo(2), photo(3), photo(4)]
        let items = StackDisplay.apply(displayed: displayed, stacks: [stack(10, [2, 4], cover: 4)], expandedIDs: [10])
        XCTAssertEqual(ids(items), [1, 2, 4, 3])
        XCTAssertEqual(items.map(\.role), [.plain, .expandedMember, .expandedMember, .plain])
        XCTAssertEqual(items.map(\.isCover), [false, false, true, false])
        XCTAssertEqual(items[1].hiddenMemberCount, 0)
        XCTAssertTrue(items[1].isExpanded)
    }

    func testExpandingAnotherStackDoesNotExpandThisOne() {
        let displayed = [photo(1), photo(2), photo(3), photo(4)]
        let stacks = [stack(10, [1, 2]), stack(11, [3, 4])]
        let items = StackDisplay.apply(displayed: displayed, stacks: stacks, expandedIDs: [11])
        XCTAssertEqual(items.map(\.role), [.collapsedStack, .expandedMember, .expandedMember])
    }

    func testCoverHiddenByAFilterFallsBackToTheFirstVisibleMember() {
        let displayed = [photo(1), photo(3), photo(4)] // 2 (the cover) is filtered out
        let items = StackDisplay.apply(displayed: displayed, stacks: [stack(10, [2, 3, 4], cover: 2)], expandedIDs: [])
        XCTAssertEqual(ids(items), [1, 3])
        XCTAssertEqual(items[1].role, .collapsedStack)
        XCTAssertEqual(items[1].hiddenMemberCount, 1)
    }

    func testNoCoverUsesTheFirstVisibleMember() {
        let items = StackDisplay.apply(displayed: [photo(5), photo(2)], stacks: [stack(10, [2, 5])], expandedIDs: [])
        XCTAssertEqual(ids(items), [5])
    }

    func testAStackWithOneVisibleMemberIsAPlainPhoto() {
        let items = StackDisplay.apply(displayed: [photo(1), photo(3)], stacks: [stack(10, [3, 4])], expandedIDs: [10])
        XCTAssertEqual(items.map(\.role), [.plain, .plain])
        XCTAssertNil(items[1].stackID)
        XCTAssertTrue(items[1].visibleMembers.isEmpty)
    }

    func testDisplayedOrderIsPreserved() {
        let displayed = [photo(9), photo(4), photo(7), photo(2)]
        let items = StackDisplay.apply(displayed: displayed, stacks: [stack(10, [2, 9])], expandedIDs: [])
        XCTAssertEqual(ids(items), [9, 4, 7]) // cover = first visible member (9) at 9's position
        XCTAssertEqual(items[0].visibleMembers.compactMap(\.id), [9, 2])
    }

    func testCopiesFollowTheirMaster() {
        let displayed = [photo(1), photo(11, master: 1), photo(2), photo(12, master: 2), photo(3)]
        let collapsed = StackDisplay.apply(displayed: displayed, stacks: [stack(10, [1, 2])], expandedIDs: [])
        XCTAssertEqual(ids(collapsed), [1, 3]) // copies hidden with their masters
        XCTAssertEqual(collapsed[0].visibleMembers.compactMap(\.id), [1, 11, 2, 12])
        XCTAssertEqual(collapsed[0].hiddenMemberCount, 3)
        let expanded = StackDisplay.apply(displayed: displayed, stacks: [stack(10, [1, 2])], expandedIDs: [10])
        XCTAssertEqual(ids(expanded), [1, 11, 2, 12, 3]) // shown with them
    }

    func testAMasterWithItsOwnCopyIsNotAStack() {
        // Only master 1 is visible (with its copy): one distinct master, so both stay plain photos, never a "+1" cell.
        let items = StackDisplay.apply(displayed: [photo(1), photo(11, master: 1)], stacks: [stack(10, [1, 2])], expandedIDs: [])
        XCTAssertEqual(items.map(\.role), [.plain, .plain])
        XCTAssertEqual(ids(items), [1, 11])
    }

    func testHiddenMasterHidesNothingElse() {
        // The master 1 is filtered out but its copy passes: the copy still belongs to the stack through its master.
        let displayed = [photo(11, master: 1), photo(2)]
        let items = StackDisplay.apply(displayed: displayed, stacks: [stack(10, [1, 2], cover: 1)], expandedIDs: [])
        XCTAssertEqual(ids(items), [11])
    }
}
