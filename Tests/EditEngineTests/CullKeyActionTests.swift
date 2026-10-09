import XCTest
@testable import PhotoApp

final class CullKeyActionTests: XCTestCase {
    func testNavigationAndExitKeys() {
        XCTAssertEqual(CullKeyAction.action(for: .leftArrow), .previous)
        XCTAssertEqual(CullKeyAction.action(for: .rightArrow), .next)
        XCTAssertEqual(CullKeyAction.action(for: .space), .next)
        XCTAssertEqual(CullKeyAction.action(for: .escape), .exit)
        XCTAssertEqual(CullKeyAction.action(for: .returnKey), .openInEditor)
    }

    func testPhotoKeysUseTheSharedTableAndZeroClearsTheRating() {
        XCTAssertEqual(CullKeyAction.action(for: .character("p")), .command(.flag(.picked)))
        XCTAssertEqual(CullKeyAction.action(for: .character("X")), .command(.flag(.rejected)))
        XCTAssertEqual(CullKeyAction.action(for: .character("u")), .command(.flag(FlagStatus.none)))
        XCTAssertEqual(CullKeyAction.action(for: .character(".")), .command(.flag(nil)))
        XCTAssertEqual(CullKeyAction.action(for: .character("3")), .command(.rating(3)))
        XCTAssertEqual(CullKeyAction.action(for: .character("0")), .command(.rating(0)), "no 'reset zoom' here")
        XCTAssertEqual(CullKeyAction.action(for: .character("6")), .command(.label(.red)))
    }

    func testOtherCharactersDoNothing() {
        for c: Character in ["a", "z", "7x".first!, "-", "/"] where PhotoKeyCommand.command(for: c) == nil {
            XCTAssertNil(CullKeyAction.action(for: .character(c)), String(c))
        }
        XCTAssertNil(CullKeyAction.action(for: .character("q")))
    }
}
