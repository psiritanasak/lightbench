import XCTest
@testable import PhotoApp

final class StackSelectionTests: XCTestCase {
    private func photo(_ id: Int64) -> Photo {
        Photo(id: id, path: "/p/\(id).jpg", filename: "\(id).jpg", fileSize: 1, importedAt: Date(timeIntervalSince1970: Double(id)))
    }

    private func items(expanded: Bool) -> [StackGridItem] {
        StackDisplay.apply(
            displayed: [photo(1), photo(2), photo(3), photo(4)],
            stacks: [StackSnapshot(id: 10, isManual: false, coverPhotoID: 2, memberIDs: [2, 3, 4])],
            expandedIDs: expanded ? [10] : []
        )
    }

    func testTickingACollapsedCoverSelectsEveryVisibleMember() {
        let cell = items(expanded: false)[1]
        XCTAssertEqual(StackSelection.ids(for: cell), [2, 3, 4])
        let selection = StackSelection.toggled(cell, in: [1])
        XCTAssertEqual(selection, [1, 2, 3, 4])
        XCTAssertTrue(StackSelection.isSelected(cell, in: selection))
    }

    func testUntickingDeselectsThemAndKeepsOthers() {
        let cell = items(expanded: false)[1]
        XCTAssertEqual(StackSelection.toggled(cell, in: [1, 2, 3, 4]), [1])
    }

    func testPartlySelectedStackIsUntickedSoTheNextTickCompletesIt() {
        let cell = items(expanded: false)[1]
        XCTAssertFalse(StackSelection.isSelected(cell, in: [2]))
        XCTAssertEqual(StackSelection.toggled(cell, in: [2]), [2, 3, 4])
    }

    func testExpandedMembersTickIndividually() {
        let all = items(expanded: true)
        let member = all[2] // photo 3
        XCTAssertEqual(StackSelection.ids(for: member), [3])
        XCTAssertEqual(StackSelection.toggled(member, in: []), [3])
        XCTAssertEqual(StackSelection.toggled(member, in: [2, 3]), [2])
    }

    func testPlainPhotoIsItself() {
        let plain = items(expanded: false)[0]
        XCTAssertEqual(StackSelection.toggled(plain, in: [4]), [1, 4])
        XCTAssertEqual(StackSelection.toggled(plain, in: [1, 4]), [4])
    }
}
