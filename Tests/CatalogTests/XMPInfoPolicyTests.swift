import XCTest
@testable import PhotoApp

final class XMPInfoPolicyTests: XCTestCase {
    private let photo = Photo(id: 1, path: "/tmp/a.jpg", filename: "a.jpg", fileSize: 1, importedAt: Date())

    private func change(_ current: PhotoInfo, _ fields: XMPLibraryFields, _ mode: XMPImportPolicy.Mode) -> XMPImportPolicy.Change {
        XMPImportPolicy.change(current: photo, currentKeywordKeys: [], fields: fields, mode: mode, currentInfo: current)
    }

    func testReplaceLetsANonEmptyFileValueWinAndNeverClearsFromAnAbsentOne() {
        let current = PhotoInfo(title: "Mine", caption: "My caption", creator: "Me", copyright: "(c) Me")
        let c = change(current, XMPLibraryFields(title: "Theirs", caption: nil, creator: "  ", copyright: "(c) Me"), .replace)
        XCTAssertEqual(c.info.title, "Theirs")
        XCTAssertNil(c.info.caption, "an absent file value leaves the catalog's alone")
        XCTAssertNil(c.info.creator, "a blank file value is absent")
        XCTAssertNil(c.info.copyright, "an equal value is no change")
        XCTAssertEqual(c.info.applying(to: current), PhotoInfo(title: "Theirs", caption: "My caption", creator: "Me", copyright: "(c) Me"))
        XCTAssertFalse(c.isEmpty)
    }

    func testFillDefaultsOnlyFillsFieldsTheCatalogHasEmpty() {
        let current = PhotoInfo(title: "Mine", caption: "", creator: "", copyright: "(c) Me")
        let c = change(current, XMPLibraryFields(title: "Theirs", caption: "Their caption", creator: "Them", copyright: "(c) Them"), .fillDefaults)
        XCTAssertNil(c.info.title)
        XCTAssertEqual(c.info.caption, "Their caption")
        XCTAssertEqual(c.info.creator, "Them")
        XCTAssertNil(c.info.copyright)
    }

    func testFileValuesAreTrimmedAndNothingToDoIsEmpty() {
        let c = change(PhotoInfo(), XMPLibraryFields(title: "  Spaced \n"), .replace)
        XCTAssertEqual(c.info.title, "Spaced")
        XCTAssertTrue(change(PhotoInfo(title: "Same"), XMPLibraryFields(title: "Same "), .replace).isEmpty)
        XCTAssertTrue(change(PhotoInfo(), XMPLibraryFields(), .replace).isEmpty)
    }

    func testInfoChangesDoNotDisturbTheOtherFieldRules() {
        let c = change(PhotoInfo(), XMPLibraryFields(rating: 4, isRejected: false, title: "T"), .replace)
        XCTAssertEqual(c.rating, 4)
        XCTAssertEqual(c.info.title, "T")
    }
}
