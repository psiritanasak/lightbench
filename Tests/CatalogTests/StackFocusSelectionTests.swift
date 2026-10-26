import XCTest
@testable import PhotoApp

/// The pure rules behind focus on stacked cells and the mixed checkbox.
final class StackFocusSelectionTests: XCTestCase {
    private func photo(_ id: Int64) -> Photo {
        Photo(id: id, path: "/p/\(id).jpg", filename: "\(id).jpg", fileSize: 1, importedAt: Date(timeIntervalSince1970: 0), rating: 0)
    }

    private func collapsed(cover: Int64, members: [Int64]) -> StackGridItem {
        StackGridItem(photo: photo(cover), role: .collapsedStack, stackID: 1, visibleMembers: members.map(photo),
                      hiddenMemberCount: members.count - 1, isCover: true)
    }

    private func plain(_ id: Int64) -> StackGridItem {
        StackGridItem(photo: photo(id), role: .plain, stackID: nil, visibleMembers: [], hiddenMemberCount: 0, isCover: false)
    }

    func testAKeyThatIsACellStaysPut() {
        let items = [plain(1), collapsed(cover: 2, members: [2, 3])]
        XCTAssertEqual(StackFocus.resolve("/p/1.jpg", in: items), "/p/1.jpg")
        XCTAssertEqual(StackFocus.resolve("/p/2.jpg", in: items), "/p/2.jpg")
    }

    func testAHiddenMemberResolvesToItsStacksCell() {
        let items = [plain(1), collapsed(cover: 2, members: [2, 3, 4])]
        XCTAssertEqual(StackFocus.resolve("/p/4.jpg", in: items), "/p/2.jpg")
    }

    func testAnUnknownKeyAndNilAreReturnedUnchanged() {
        let items = [plain(1)]
        XCTAssertEqual(StackFocus.resolve("/elsewhere.jpg", in: items), "/elsewhere.jpg")
        XCTAssertNil(StackFocus.resolve(nil, in: items))
    }

    func testAnExpandedMemberIsItsOwnCell() {
        let member = StackGridItem(photo: photo(3), role: .expandedMember, stackID: 1, visibleMembers: [photo(2), photo(3)], hiddenMemberCount: 0, isCover: false)
        XCTAssertEqual(StackFocus.resolve("/p/3.jpg", in: [member]), "/p/3.jpg")
    }

    func testSelectionStateNoneAllAndPartial() {
        let item = collapsed(cover: 1, members: [1, 2, 3])
        XCTAssertEqual(StackSelection.state(of: item, in: []), .none)
        XCTAssertEqual(StackSelection.state(of: item, in: [1]), .partial)
        XCTAssertEqual(StackSelection.state(of: item, in: [1, 2]), .partial)
        XCTAssertEqual(StackSelection.state(of: item, in: [1, 2, 3]), .all)
        XCTAssertEqual(StackSelection.state(of: item, in: [9]), .none)
    }

    func testAPlainCellIsNeverPartial() {
        XCTAssertEqual(StackSelection.state(of: plain(1), in: [1]), .all)
        XCTAssertEqual(StackSelection.state(of: plain(1), in: []), .none)
    }
}
