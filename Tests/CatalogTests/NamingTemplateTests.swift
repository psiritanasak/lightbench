import XCTest
@testable import PhotoApp

final class NamingTemplateTests: XCTestCase {
    /// 2026-03-05 14:07:09 as UTC digits (the `CaptureDate` convention).
    private let capture = Date(timeIntervalSince1970: 1_772_719_629)

    private var savedTimeZone: TimeZone!

    override func setUp() {
        super.setUp()
        // Pin a non-UTC default zone: otherwise a regression that formats in the local zone
        // instead of UTC would pass on a machine that happens to be in UTC.
        savedTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Pacific/Auckland")!
    }

    override func tearDown() {
        NSTimeZone.default = savedTimeZone
        super.tearDown()
    }

    private func context(
        base: String = "IMG_0042", ext: String = "jpg", index: Int = 0, start: Int = 1,
        rating: Int = 0, label: ColorLabel = .none, flag: FlagStatus = .none
    ) -> NamingContext {
        NamingContext(
            baseName: base, fileExtension: ext, sequenceIndex: index, sequenceStart: start,
            captureDate: capture, rating: rating, colorLabel: label, flagStatus: flag
        )
    }

    private func render(_ template: String, _ ctx: NamingContext? = nil) -> Result<String, NamingError> {
        NamingTemplate.render(template, context: ctx ?? context())
    }

    // MARK: Tokens

    func testDefaultTemplateReproducesTheOriginalNameExactly() {
        XCTAssertEqual(try render(NamingTemplate.defaultTemplate).get(), "IMG_0042.jpg")
        XCTAssertEqual(try render("{name}", context(base: "My Photo (2)", ext: "NEF")).get(), "My Photo (2).NEF")
    }

    func testSequenceIsOneBasedAndZeroPaddedToThreeByDefault() {
        XCTAssertEqual(try render("{seq}", context(index: 0)).get(), "001.jpg")
        XCTAssertEqual(try render("{seq}", context(index: 41)).get(), "042.jpg")
        XCTAssertEqual(try render("{seq}", context(index: 1233)).get(), "1234.jpg") // never truncates
    }

    func testSequenceWidthAndStart() {
        XCTAssertEqual(try render("{seq:5}", context(index: 2)).get(), "00003.jpg")
        XCTAssertEqual(try render("{seq:1}", context(index: 8)).get(), "9.jpg")
        XCTAssertEqual(try render("{seq}", context(index: 2, start: 100)).get(), "102.jpg")
    }

    func testInvalidSequenceWidthsAreRejected() {
        for bad in ["{seq:0}", "{seq:10}", "{seq:x}", "{seq:}", "{seq:-2}", "{seq:+4}", "{seq:04}", "{seq: 4}"] {
            guard case .failure(.invalidSequenceWidth) = render(bad) else {
                XCTFail("\(bad) should be an invalid sequence width")
                continue
            }
        }
    }

    func testDateAndDatetimeUseTheCaptureWallClockDigits() {
        XCTAssertEqual(try render("{date}").get(), "2026-03-05.jpg")
        XCTAssertEqual(try render("{datetime}").get(), "20260305-140709.jpg")
        XCTAssertEqual(try render("{date}_{seq}_{name}").get(), "2026-03-05_001_IMG_0042.jpg")
    }

    func testRatingLabelAndFlagTokens() {
        XCTAssertEqual(try render("{rating}star", context(rating: 4)).get(), "4star.jpg")
        XCTAssertEqual(try render("{rating}", context(rating: 99)).get(), "5.jpg") // clamped
        XCTAssertEqual(try render("{name}-{label}", context(label: .purple)).get(), "IMG_0042-purple.jpg")
        XCTAssertEqual(try render("{name}-{flag}", context(flag: .rejected)).get(), "IMG_0042-rejected.jpg")
    }

    func testEmptyLabelAndFlagLeaveTheSurroundingLiteralButTrimTheEnds() {
        XCTAssertEqual(try render("{name}_{label}").get(), "IMG_0042_.jpg") // interior/trailing underscore kept
        XCTAssertEqual(try render("{label}{flag}{name}").get(), "IMG_0042.jpg")
    }

    // MARK: Syntax

    func testEscapedBracesAreLiteral() {
        XCTAssertEqual(try render("{{{name}}}").get(), "{IMG_0042}.jpg")
    }

    func testSyntaxErrors() {
        XCTAssertEqual(NamingTemplate.validate(""), .emptyTemplate)
        XCTAssertEqual(NamingTemplate.validate("{nope}"), .unknownToken("nope"))
        XCTAssertEqual(NamingTemplate.validate("abc{name"), .unterminatedBrace)
        XCTAssertEqual(NamingTemplate.validate("abc}"), .strayClosingBrace)
        XCTAssertNil(NamingTemplate.validate("{date}_{seq:4}_{name}"))
    }

    func testErrorsHaveHumanReadableDescriptions() {
        XCTAssertTrue(NamingError.unknownToken("x").localizedDescription.contains("{x}"))
        XCTAssertFalse(NamingError.tooLong.localizedDescription.isEmpty)
    }

    // MARK: Sanitizing and limits

    func testPathSeparatorsColonAndControlCharactersAreRemoved() {
        XCTAssertEqual(try render("a/b:c\u{07}d").get(), "abcd.jpg")
        XCTAssertEqual(try render("{name}_x", context(base: "x/y")).get(), "xy_x.jpg")
    }

    func testLeadingAndTrailingDotsAndSpacesAreTrimmed() {
        XCTAssertEqual(try render("  ..hello..  ").get(), "hello.jpg")
        XCTAssertEqual(try render("a. .b").get(), "a. .b.jpg") // interior kept
    }

    func testDotOnlyOrSeparatorOnlyResultIsEmpty() {
        guard case .failure(.emptyResult) = render("...") else { return XCTFail() }
        guard case .failure(.emptyResult) = render("/:/") else { return XCTFail() }
        guard case .failure(.emptyResult) = render("{label}", context(label: .none)) else { return XCTFail() }
    }

    func testFileNameLimitIsMeasuredInUTF8BytesOfTheWholeName() {
        // 251 ASCII + ".jpg" = 255 bytes: allowed. 252 + ".jpg" = 256: rejected.
        XCTAssertEqual(try render(String(repeating: "a", count: 251)).get().utf8.count, 255)
        guard case .failure(.tooLong) = render(String(repeating: "a", count: 252)) else { return XCTFail() }
        // Multi-byte: 3-byte scalars count as 3 each. 84 * 3 = 252 + 4 = 256 -> too long.
        guard case .failure(.tooLong) = render(String(repeating: "日", count: 84)) else { return XCTFail() }
        XCTAssertNoThrow(try render(String(repeating: "日", count: 83)).get())
    }

    func testAResultIdenticalToTheOriginalBaseNameIsReturnedUntouched() throws {
        // Legal POSIX names the sanitizer would otherwise change.
        XCTAssertEqual(try render("{name}", context(base: "a:b")).get(), "a:b.jpg")
        XCTAssertEqual(try render("{name}", context(base: ".hidden")).get(), ".hidden.jpg")
        XCTAssertEqual(try render("{name}", context(base: " padded ")).get(), " padded .jpg")
        XCTAssertEqual(try render("{name}", context(base: "IMG..1")).get(), "IMG..1.jpg")
        // ...but the moment the template changes the name, sanitizing applies again.
        XCTAssertEqual(try render("{name}x", context(base: "a:b")).get(), "abx.jpg")
    }

    func testBidiOverridesZeroWidthAndOtherInvisibleFormatCharactersAreRemoved() throws {
        // U+202E RLO would display "x<gnp>.jpg" as "xgpj.png" in Finder.
        XCTAssertEqual(try render("x\u{202E}gnp").get(), "xgnp.jpg")
        for scalar in ["\u{200B}", "\u{FEFF}", "\u{200E}", "\u{2066}", "\u{2028}", "\u{2029}", "\u{0085}", "\u{061C}"] {
            XCTAssertEqual(try render("a\(scalar)b").get(), "ab.jpg", "U+\(scalar.unicodeScalars.first!.value)")
        }
        // A trailing invisible character must not survive the trim either.
        XCTAssertEqual(try render("name\u{200B}").get(), "name.jpg")
    }

    // MARK: Sequence range

    func testNegativeSequenceStartIsRejectedNotRenderedWithALeadingDash() {
        guard case .failure(.sequenceOutOfRange) = render("{seq}", context(index: 0, start: -1)) else { return XCTFail() }
        guard case .failure(.sequenceOutOfRange) = render("{seq}", context(index: 0, start: Int.min)) else { return XCTFail() }
        XCTAssertEqual(try render("{seq}", context(index: 1, start: -1)).get(), "000.jpg") // -1 + 1 = 0 is fine
    }

    func testSequenceOverflowIsAnErrorNotACrash() {
        guard case .failure(.sequenceOutOfRange) = render("{seq}", context(index: 5, start: Int.max)) else { return XCTFail() }
        XCTAssertEqual(try render("{seq:9}", context(index: 0, start: 0)).get(), "000000000.jpg")
    }

    // MARK: Compiled templates

    func testACompiledTemplateRendersLikeTheConvenienceAPIAndIsReusable() throws {
        let compiled = try NamingTemplate.compile("{date}_{seq:4}_{name}").get()
        for index in 0..<3 {
            let ctx = context(index: index)
            XCTAssertEqual(try compiled.render(context: ctx).get(), try render("{date}_{seq:4}_{name}", ctx).get())
        }
        XCTAssertEqual(try compiled.render(context: context(index: 2)).get(), "2026-03-05_0003_IMG_0042.jpg")
    }

    func testAdjacentTokensAndStandaloneClosingBracePairs() {
        XCTAssertEqual(try render("{name}{seq}").get(), "IMG_0042001.jpg")
        XCTAssertEqual(try render("a}}b").get(), "a}b.jpg")
        XCTAssertEqual(try render("{{}}").get(), "{}.jpg")
    }

    func testParserEdgeCases() {
        XCTAssertEqual(NamingTemplate.validate("{name}}"), .strayClosingBrace)
        XCTAssertEqual(NamingTemplate.validate("{{name}"), .strayClosingBrace)
        XCTAssertEqual(NamingTemplate.validate("{seq:4"), .unterminatedBrace)
        XCTAssertEqual(NamingTemplate.validate("{a{b}"), .unknownToken("a{b"))
        XCTAssertEqual(NamingTemplate.validate("{}"), .unknownToken(""))
    }

    // MARK: Extension

    func testOriginalExtensionIsAlwaysAppendedWithCasePreserved() {
        XCTAssertEqual(try render("{seq}", context(ext: "JPEG")).get(), "001.JPEG")
        XCTAssertEqual(try render("{seq}", context(ext: "")).get(), "001")
    }

    func testTemplateCannotChangeTheExtension() {
        XCTAssertEqual(try render("photo.png").get(), "photo.png.jpg")
    }

    // MARK: Unicode

    func testUnicodeBaseNamesSurvive() {
        XCTAssertEqual(try render("{name}", context(base: "ภาพถ่าย 東京 🌸")).get(), "ภาพถ่าย 東京 🌸.jpg")
    }
}
