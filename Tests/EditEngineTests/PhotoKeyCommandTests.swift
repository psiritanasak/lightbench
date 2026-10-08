import XCTest
@testable import PhotoApp

final class PhotoKeyCommandTests: XCTestCase {
    func testRatingKeys() {
        for d in 0...5 {
            XCTAssertEqual(PhotoKeyCommand.command(for: Character(String(d))), .rating(d))
        }
        for c in ["6", "7", "8", "9"] as [Character] {
            if case .rating = PhotoKeyCommand.command(for: c) { XCTFail("\(c) must be a label key") }
        }
    }

    func testZeroExcludedWhenNotAllowed() {
        XCTAssertNil(PhotoKeyCommand.command(for: "0", allowsZero: false))
        for d in 1...5 { XCTAssertEqual(PhotoKeyCommand.command(for: Character(String(d)), allowsZero: false), .rating(d)) }
    }

    func testLabelKeys() {
        XCTAssertEqual(PhotoKeyCommand.command(for: "6"), .label(.red))
        XCTAssertEqual(PhotoKeyCommand.command(for: "7"), .label(.yellow))
        XCTAssertEqual(PhotoKeyCommand.command(for: "8"), .label(.green))
        XCTAssertEqual(PhotoKeyCommand.command(for: "9"), .label(.blue))
    }

    func testFlagKeysBothCases() {
        for c in [".", "f", "F"] as [Character] { XCTAssertEqual(PhotoKeyCommand.command(for: c), .flag(nil)) }
        for c in ["p", "P"] as [Character] { XCTAssertEqual(PhotoKeyCommand.command(for: c), .flag(.picked)) }
        for c in ["x", "X"] as [Character] { XCTAssertEqual(PhotoKeyCommand.command(for: c), .flag(.rejected)) }
        for c in ["u", "U"] as [Character] { XCTAssertEqual(PhotoKeyCommand.command(for: c), .flag(FlagStatus.none)) }
    }

    func testNonPhotoKeysAreNil() {
        for c in ["a", "z", " ", "-", "=", "\u{1B}"] as [Character] { XCTAssertNil(PhotoKeyCommand.command(for: c), "\(c)") }
        // Characters whose wholeNumberValue is outside 0...5 or nil are not rating keys (Arabic-Indic 7, a vulgar fraction).
        XCTAssertNil(PhotoKeyCommand.command(for: "٧"))
        XCTAssertNil(PhotoKeyCommand.command(for: "½"))
    }

    func testFlagResolution() {
        let toggle = PhotoKeyCommand.flag(nil)
        XCTAssertEqual(toggle.flagStatus(from: .none), .picked)
        XCTAssertEqual(toggle.flagStatus(from: .picked), FlagStatus.none)
        XCTAssertEqual(toggle.flagStatus(from: .rejected), FlagStatus.none)
        XCTAssertEqual(PhotoKeyCommand.flag(.rejected).flagStatus(from: .rejected), .rejected)
        XCTAssertEqual(PhotoKeyCommand.flag(.picked).flagStatus(from: .picked), .picked)
        XCTAssertEqual(PhotoKeyCommand.flag(FlagStatus.none).flagStatus(from: .picked), FlagStatus.none)
        XCTAssertNil(PhotoKeyCommand.rating(3).flagStatus(from: .none))
    }

    func testLabelResolution() {
        XCTAssertEqual(PhotoKeyCommand.label(.red).label(from: .none), .red)
        XCTAssertEqual(PhotoKeyCommand.label(.red).label(from: .red), ColorLabel.none)
        XCTAssertEqual(PhotoKeyCommand.label(.red).label(from: .blue), .red)
        XCTAssertNil(PhotoKeyCommand.flag(nil).label(from: .red))
    }
}
