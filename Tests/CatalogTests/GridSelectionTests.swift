import XCTest
@testable import PhotoApp

/// The pure click and keyboard selection rules of the Library grid.
final class GridSelectionTests: XCTestCase {
    private func photo(_ id: Int64) -> Photo {
        Photo(id: id, path: "/p/\(id).jpg", filename: "\(id).jpg", fileSize: 1, importedAt: Date(timeIntervalSince1970: 0), rating: 0)
    }

    private func plain(_ id: Int64) -> StackGridItem {
        StackGridItem(photo: photo(id), role: .plain, stackID: nil, visibleMembers: [], hiddenMemberCount: 0, isCover: false)
    }

    private func collapsed(cover: Int64, members: [Int64]) -> StackGridItem {
        StackGridItem(photo: photo(cover), role: .collapsedStack, stackID: 1, visibleMembers: members.map(photo),
                      hiddenMemberCount: members.count - 1, isCover: true)
    }

    private func key(_ id: Int64) -> String { "/p/\(id).jpg" }
    private var six: [StackGridItem] { (1...6).map(plain) }

    func testClickKindFollowsTheModifiers() {
        XCTAssertEqual(GridSelection.ClickKind(command: false, shift: false), .plain)
        XCTAssertEqual(GridSelection.ClickKind(command: true, shift: false), .toggle)
        XCTAssertEqual(GridSelection.ClickKind(command: false, shift: true), .extend)
        XCTAssertEqual(GridSelection.ClickKind(command: true, shift: true), .extend)
    }

    func testASingleClickSelectsAndADoubleClickOpens() {
        XCTAssertEqual(GridSelection.clickEffect(clickCount: 1, command: false, shift: false), .select(.plain))
        XCTAssertEqual(GridSelection.clickEffect(clickCount: 2, command: false, shift: false), .open)
        XCTAssertEqual(GridSelection.clickEffect(clickCount: 3, command: false, shift: false), .open)
    }

    func testADoubleClickWithCommandOrShiftDoesNothing() {
        XCTAssertEqual(GridSelection.clickEffect(clickCount: 2, command: true, shift: false), .ignore)
        XCTAssertEqual(GridSelection.clickEffect(clickCount: 2, command: false, shift: true), .ignore)
    }

    func testPlainClickReplacesTheSelectionAndAnchorsThere() {
        let out = GridSelection.selectingOnly(plain(3))
        XCTAssertEqual(out.selection, [3])
        XCTAssertEqual(out.anchor, GridSelection.Anchor(key: key(3), base: []))
        XCTAssertEqual(out.focusKey, key(3))
    }

    func testCommandClickAddsWithoutTouchingTheRest() {
        let out = GridSelection.toggling(plain(4), in: [1, 2])
        XCTAssertEqual(out.selection, [1, 2, 4])
        XCTAssertEqual(out.anchor, GridSelection.Anchor(key: key(4), base: [1, 2]))
    }

    func testCommandClickOnASelectedCellDeselectsItAndAnchorsThere() {
        let out = GridSelection.toggling(plain(2), in: [1, 2])
        XCTAssertEqual(out.selection, [1])
        XCTAssertEqual(out.anchor, GridSelection.Anchor(key: key(2), base: [1]))
        XCTAssertEqual(out.focusKey, key(2))
    }

    func testShiftClickSelectsTheRangeInEitherDirection() {
        let anchor = GridSelection.Anchor(key: key(3), base: [])
        let forward = GridSelection.extending(to: 5, in: six, selection: [3], anchor: anchor, focusKey: key(3))
        XCTAssertEqual(forward?.selection, [3, 4, 5, 6])
        let backward = GridSelection.extending(to: 0, in: six, selection: [3], anchor: anchor, focusKey: key(3))
        XCTAssertEqual(backward?.selection, [1, 2, 3])
        XCTAssertEqual(backward?.focusKey, key(1))
    }

    func testShiftClickAfterCommandClickAddsTheRangeToTheEarlierSelection() {
        var selection = GridSelection.selectingOnly(plain(1))
        selection = GridSelection.toggling(plain(4), in: selection.selection)
        XCTAssertEqual(selection.selection, [1, 4])
        let shift6 = GridSelection.extending(to: 5, in: six, selection: selection.selection, anchor: selection.anchor, focusKey: selection.focusKey)
        XCTAssertEqual(shift6?.selection, [1, 4, 5, 6])
        let shift5 = GridSelection.extending(to: 4, in: six, selection: shift6?.selection ?? [], anchor: shift6?.anchor, focusKey: shift6?.focusKey)
        XCTAssertEqual(shift5?.selection, [1, 4, 5])
    }

    func testRepeatedShiftClicksReplaceTheRangeAndCanShrinkIt() {
        let anchor = GridSelection.Anchor(key: key(2), base: [])
        let wide = GridSelection.extending(to: 5, in: six, selection: [2], anchor: anchor, focusKey: key(2))
        XCTAssertEqual(wide?.selection, [2, 3, 4, 5, 6])
        let narrow = GridSelection.extending(to: 2, in: six, selection: wide?.selection ?? [], anchor: wide?.anchor, focusKey: wide?.focusKey)
        XCTAssertEqual(narrow?.selection, [2, 3])
        XCTAssertEqual(narrow?.anchor, anchor)
    }

    func testWithNoAnchorTheRangeStartsAtTheFocusAndKeepsTheSelection() {
        let out = GridSelection.extending(to: 4, in: six, selection: [1], anchor: nil, focusKey: key(3))
        XCTAssertEqual(out?.selection, [1, 3, 4, 5])
        XCTAssertEqual(out?.anchor, GridSelection.Anchor(key: key(3), base: [1]))
    }

    func testWithNoAnchorAndNoFocusExtendIsNil() {
        XCTAssertNil(GridSelection.extending(to: 2, in: six, selection: [1], anchor: nil, focusKey: nil))
        XCTAssertNil(GridSelection.extending(to: 2, in: six, selection: [1], anchor: nil, focusKey: "/elsewhere.jpg"))
    }

    func testAnAnchorThatLeftTheListAfterAFilterChangeFallsBackToTheFocus() {
        let anchor = GridSelection.Anchor(key: key(99), base: [1])
        let out = GridSelection.extending(to: 5, in: six, selection: [1, 4], anchor: anchor, focusKey: key(4))
        XCTAssertEqual(out?.selection, [1, 4, 5, 6])
        XCTAssertEqual(out?.anchor?.key, key(4))
    }

    func testAnAnchorHiddenInACollapsedStackResolvesToTheStackCell() {
        let cells = [plain(1), collapsed(cover: 2, members: [2, 7, 8]), plain(3)]
        let anchor = GridSelection.Anchor(key: key(8), base: [])
        let out = GridSelection.extending(to: 2, in: cells, selection: [], anchor: anchor, focusKey: nil)
        XCTAssertEqual(out?.selection, [2, 7, 8, 3])
        XCTAssertEqual(out?.anchor, anchor)
    }

    func testABaseIDNoLongerSelectedIsNotBroughtBack() {
        let anchor = GridSelection.Anchor(key: key(3), base: [1, 2])
        let out = GridSelection.extending(to: 3, in: six, selection: [2, 3], anchor: anchor, focusKey: key(3))
        XCTAssertEqual(out?.selection, [2, 3, 4])
    }

    func testClickingACollapsedStackSelectsAllItsVisibleMembers() {
        let out = GridSelection.selectingOnly(collapsed(cover: 2, members: [2, 7, 8]))
        XCTAssertEqual(out.selection, [2, 7, 8])
        XCTAssertEqual(out.focusKey, key(2))
    }

    func testARangeThroughACollapsedStackIncludesItsMembers() {
        let cells = [plain(1), collapsed(cover: 2, members: [2, 7, 8]), plain(3)]
        let out = GridSelection.extending(to: 2, in: cells, selection: [1], anchor: GridSelection.Anchor(key: key(1), base: []), focusKey: key(1))
        XCTAssertEqual(out?.selection, [1, 2, 7, 8, 3])
    }

    func testCommandClickOnAPartlySelectedStackCompletesItLikeTheCheckbox() {
        let stack = collapsed(cover: 2, members: [2, 7, 8])
        let out = GridSelection.toggling(stack, in: [2, 5])
        XCTAssertEqual(out.selection, StackSelection.toggled(stack, in: [2, 5]))
        XCTAssertEqual(out.selection, [2, 5, 7, 8])
        XCTAssertEqual(out.anchor?.base, [5])
    }

    func testSelectAllIsEveryVisibleMemberOfEveryCell() {
        let cells = [plain(1), collapsed(cover: 2, members: [2, 7, 8]), plain(3)]
        XCTAssertEqual(GridSelection.allIDs(in: cells), [1, 2, 3, 7, 8])
    }

    func testExtendOutOfRangeIsNil() {
        let anchor = GridSelection.Anchor(key: key(1), base: [])
        XCTAssertNil(GridSelection.extending(to: -1, in: six, selection: [1], anchor: anchor, focusKey: key(1)))
        XCTAssertNil(GridSelection.extending(to: 6, in: six, selection: [1], anchor: anchor, focusKey: key(1)))
    }

    func testAPlainArrowReplacesAMultiSelectionAndShiftArrowExtendsFromThere() {
        let moved = GridSelection.selectingOnly(six[3])
        XCTAssertEqual(moved.selection, [4])
        let extended = GridSelection.extending(to: 4, in: six, selection: moved.selection, anchor: moved.anchor, focusKey: moved.focusKey)
        XCTAssertEqual(extended?.selection, [4, 5])
        XCTAssertEqual(extended?.anchor, GridSelection.Anchor(key: key(4), base: []))
    }

    func testOnlyCommandAAndCommandDAreCommandKeys() {
        func k(_ c: Character, command: Bool = true, shift: Bool = false, option: Bool = false) -> GridSelection.CommandKey? {
            GridSelection.commandKey(character: c, command: command, shift: shift, option: option, control: false)
        }
        XCTAssertEqual(k("a"), .selectAll)
        XCTAssertEqual(k("d"), .clearSelection)
        XCTAssertNil(k("a", shift: true))
        XCTAssertNil(k("a", option: true))
        XCTAssertNil(k("a", command: false))
        XCTAssertNil(k("x"))
        XCTAssertNil(GridSelection.commandKey(character: nil, command: true, shift: false, option: false, control: false))
    }
}
