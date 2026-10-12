import XCTest
@testable import PhotoApp

final class SidebarRowsTests: XCTestCase {
    private func collection(_ id: Int64, _ name: String, folder: Bool = false, parent: Int64? = nil) -> PhotoCollection {
        PhotoCollection(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0), parentId: parent, isFolder: folder, folderPath: nil)
    }
    private func smart(_ id: Int64, _ name: String) -> SmartCollection {
        SmartCollection(id: id, name: name, criteria: SmartCollectionCriteria(), createdAt: Date(timeIntervalSince1970: 0))
    }

    private var sample: (collections: [PhotoCollection], smart: [SmartCollection]) {
        ([collection(1, "Trips"), collection(2, "Family"),
          collection(10, "2024", folder: true), collection(11, "Alps", folder: true, parent: 10), collection(12, "Zoo", folder: true, parent: 10),
          collection(20, "Archive", folder: true)],
         [smart(5, "Five stars")])
    }

    func testRowOrderAndKinds() {
        let rows = SidebarRows.rows(collections: sample.collections, smartCollections: sample.smart, expandedFolders: [])
        XCTAssertEqual(rows.map(\.id), ["all", "header-collections", "collection-1", "collection-2", "action-new-collection",
                                        "header-smart", "smart-5", "action-save-filters",
                                        "header-folders", "folder-10", "folder-20"])
        XCTAssertEqual(rows.map(\.kind), [.item, .header, .item, .item, .action, .header, .item, .action, .header, .item, .item])
        XCTAssertEqual(rows.first { $0.id == "collection-1" }?.filter, .collection(1))
        XCTAssertEqual(rows.first { $0.id == "smart-5" }?.filter, .smartCollection(5))
        XCTAssertEqual(rows.first { $0.id == "all" }?.filter, .allPhotos)
        XCTAssertEqual(rows.first { $0.id == "action-save-filters" }?.action, .saveFilters)
    }

    func testOnlySmartCollectionRowsHaveATooltipDescribingTheirCriteria() {
        var criteria = SmartCollectionCriteria(minimumRating: 3, flag: .picked)
        criteria.searchQuery = "iso:>1600"
        let described = SmartCollection(id: 6, name: "High ISO", criteria: criteria, createdAt: Date(timeIntervalSince1970: 0))
        let rows = SidebarRows.rows(collections: sample.collections, smartCollections: [described], expandedFolders: [])
        XCTAssertEqual(rows.first { $0.id == "smart-6" }?.tooltip, "3+ stars · Picked · Search: iso:>1600")
        XCTAssertNil(rows.first { $0.id == "collection-1" }?.tooltip)
        XCTAssertNil(rows.first { $0.id == "all" }?.tooltip)
        XCTAssertNil(rows.first { $0.id == "folder-10" }?.tooltip)
        XCTAssertNil(rows.first { $0.id == "action-save-filters" }?.tooltip)
    }

    func testNoFoldersMeansNoFoldersSection() {
        let rows = SidebarRows.rows(collections: [collection(1, "Trips")], smartCollections: [], expandedFolders: [])
        XCTAssertFalse(rows.contains { $0.id == "header-folders" })
    }

    func testFolderChildrenAppearOnlyUnderExpandedFolders() {
        let collapsed = SidebarRows.rows(collections: sample.collections, smartCollections: [], expandedFolders: [])
        XCTAssertNil(collapsed.first { $0.id == "folder-11" })
        let root = collapsed.first { $0.id == "folder-10" }
        XCTAssertEqual(root?.hasChildren, true)
        XCTAssertEqual(root?.isExpanded, false)
        XCTAssertEqual(collapsed.first { $0.id == "folder-20" }?.hasChildren, false, "a leaf folder has no disclosure")

        let expanded = SidebarRows.rows(collections: sample.collections, smartCollections: [], expandedFolders: [10])
        let ids = expanded.filter { $0.id.hasPrefix("folder-") }.map(\.id)
        XCTAssertEqual(ids, ["folder-10", "folder-11", "folder-12", "folder-20"], "children sorted by name, right after their parent")
        XCTAssertEqual(expanded.first { $0.id == "folder-11" }?.depth, 1)
        XCTAssertEqual(expanded.first { $0.id == "folder-10" }?.isExpanded, true)
    }

    func testExpandedSetIgnoresFoldersWithoutChildren() {
        let rows = SidebarRows.rows(collections: sample.collections, smartCollections: [], expandedFolders: [20])
        XCTAssertEqual(rows.first { $0.id == "folder-20" }?.isExpanded, false)
    }

    func testUpDownWalkThroughVisibleItemsAndClamp() {
        let rows = SidebarRows.rows(collections: sample.collections, smartCollections: sample.smart, expandedFolders: [])
        XCTAssertEqual(SidebarRows.selectableFilters(in: rows),
                       [.allPhotos, .collection(1), .collection(2), .smartCollection(5), .collection(10), .collection(20)])
        XCTAssertEqual(SidebarRows.moved(from: .allPhotos, by: 1, in: rows), .collection(1))
        XCTAssertEqual(SidebarRows.moved(from: .collection(2), by: 1, in: rows), .smartCollection(5), "headers and actions are skipped")
        XCTAssertEqual(SidebarRows.moved(from: .collection(20), by: 1, in: rows), .collection(20), "clamped at the end")
        XCTAssertEqual(SidebarRows.moved(from: .allPhotos, by: -1, in: rows), .allPhotos, "clamped at the start")
        XCTAssertEqual(SidebarRows.moved(from: .collection(999), by: 1, in: rows), .allPhotos, "a hidden selection restarts at the top")
    }

    func testRightExpandsAndLeftCollapsesOrSelectsTheParent() {
        let collapsed = SidebarRows.rows(collections: sample.collections, smartCollections: [], expandedFolders: [])
        let nowExpanded = SidebarRows.expanding(.collection(10), expanded: [], in: collapsed)
        XCTAssertEqual(nowExpanded, [10])
        XCTAssertEqual(SidebarRows.expanding(.collection(20), expanded: [], in: collapsed), [], "a leaf folder does not expand")
        XCTAssertEqual(SidebarRows.expanding(.collection(1), expanded: [], in: collapsed), [], "a plain collection does not expand")

        let expanded = SidebarRows.rows(collections: sample.collections, smartCollections: [], expandedFolders: [10])
        let collapsedAgain = SidebarRows.collapsing(.collection(10), expanded: [10], in: expanded)
        XCTAssertEqual(collapsedAgain.expanded, [])
        XCTAssertEqual(collapsedAgain.selection, .collection(10))
        let toParent = SidebarRows.collapsing(.collection(11), expanded: [10], in: expanded)
        XCTAssertEqual(toParent.selection, .collection(10), "Left on a child selects its parent")
        XCTAssertEqual(toParent.expanded, [10])
        XCTAssertEqual(SidebarRows.collapsing(.collection(20), expanded: [], in: collapsed).selection, .collection(20), "a root leaf stays put")
    }

    private func deepTree() -> [PhotoCollection] {
        [collection(1, "a", folder: true), collection(2, "b", folder: true, parent: 1), collection(3, "c", folder: true, parent: 2)]
    }

    func testCollapsingAParentMovesAHiddenSelectionToTheParent() {
        let all = deepTree()
        let open: Set<Int64> = [1, 2]
        let rows = SidebarRows.rows(collections: all, smartCollections: [], expandedFolders: open)
        let result = SidebarRows.toggled(1, selected: .collection(3), expanded: open, in: rows)
        XCTAssertEqual(result.selection, .collection(1), "depth-2 selection is inside the collapsed folder")
        XCTAssertEqual(result.expanded, [2])
        // A selection outside the folder stays; expanding never moves it.
        XCTAssertEqual(SidebarRows.toggled(1, selected: .allPhotos, expanded: open, in: rows).selection, .allPhotos)
        let closedRows = SidebarRows.rows(collections: all, smartCollections: [], expandedFolders: [])
        let expandedResult = SidebarRows.toggled(1, selected: .collection(1), expanded: [], in: closedRows)
        XCTAssertEqual(expandedResult.expanded, [1])
        XCTAssertEqual(expandedResult.selection, .collection(1))
    }

    func testLeftOnAnExpandedChildCollapsesItAndDeepRowsNeedEveryAncestorExpanded() {
        let all = deepTree()
        let rows = SidebarRows.rows(collections: all, smartCollections: [], expandedFolders: [1, 2])
        XCTAssertEqual(rows.filter { $0.kind == .item && $0.folderID != nil }.map(\.depth), [0, 1, 2])
        let result = SidebarRows.collapsing(.collection(2), expanded: [1, 2], in: rows)
        XCTAssertEqual(result.selection, .collection(2))
        XCTAssertEqual(result.expanded, [1])
        // Folder 3 shows only when both ancestors are expanded.
        let partial = SidebarRows.rows(collections: all, smartCollections: [], expandedFolders: [2])
        XCTAssertFalse(partial.contains { $0.folderID == 3 })
    }

    func testLeftOnAPlainOrSmartCollectionStaysPut() {
        let rows = SidebarRows.rows(collections: [collection(7, "plain")], smartCollections: [smart(9, "s")], expandedFolders: [])
        XCTAssertEqual(SidebarRows.collapsing(.collection(7), expanded: [], in: rows).selection, .collection(7))
        XCTAssertEqual(SidebarRows.collapsing(.smartCollection(9), expanded: [], in: rows).selection, .smartCollection(9))
    }

    func testPruneDropsDeletedAndNonFolderIDs() {
        let kept = SidebarRows.pruned([1, 2, 99], collections: [collection(1, "a", folder: true), collection(2, "b")])
        XCTAssertEqual(kept, [1])
    }
}
