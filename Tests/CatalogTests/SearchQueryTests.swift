import XCTest
@testable import PhotoApp

final class SearchQueryTests: XCTestCase {
    private func ts(_ exif: String) -> Double { CaptureDate.parseEXIFDate(exif)!.timeIntervalSince1970 }

    private func photo(_ id: Int64, _ name: String = "p.jpg", rating: Int = 0, flag: FlagStatus = .none,
                       label: ColorLabel = .none) -> Photo {
        var p = Photo(id: id, path: "/tmp/\(name)", filename: name, fileSize: 1, importedAt: Date(timeIntervalSince1970: 0))
        p.rating = rating; p.flagStatus = flag; p.colorLabel = label
        return p
    }

    private func meta(_ id: Int64, iso: Int? = nil, make: String? = nil, model: String? = nil, lens: String? = nil,
                      focal: Double? = nil, aperture: Double? = nil, shutter: Double? = nil, date: String? = nil) -> PhotoMetadata {
        PhotoMetadata(photoId: id, fileSize: 1, mtime: 1, readerRevision: PhotoMetadata.currentReaderRevision,
                      captureDate: date.map(ts), iso: iso, cameraMake: make, cameraModel: model, lens: lens,
                      focalLength: focal, aperture: aperture, shutter: shutter, pixelWidth: nil, pixelHeight: nil,
                      scannedAt: Date())
    }

    private func matches(_ query: String, _ photo: Photo, _ metadata: PhotoMetadata? = nil, keywords: [String] = []) -> Bool {
        SearchQuery(parsing: query).matches(photo, metadata: metadata, keywordNames: keywords)
    }

    // MARK: Plain text

    func testPlainWordsMatchFilenameOrKeywordAndAllWordsMustMatch() {
        let p = photo(1, "Sunset Beach.jpg")
        XCTAssertTrue(matches("sunset", p))
        XCTAssertTrue(matches("SUN", p), "case-insensitive substring")
        XCTAssertTrue(matches("sunset beach", p), "two words, both present")
        XCTAssertFalse(matches("sunset mountain", p))
        XCTAssertTrue(matches("sunset mountain", p, keywords: ["Mountain"]), "a word may be satisfied by a keyword")
        XCTAssertTrue(matches("\"sunset beach\"", p), "a quoted phrase is one term")
        XCTAssertFalse(matches("\"beach sunset\"", p), "a quoted phrase keeps its word order")
    }

    func testEmptyAndWhitespaceQueriesHaveNoTerms() {
        XCTAssertTrue(SearchQuery(parsing: "").isEmpty)
        XCTAssertTrue(SearchQuery(parsing: "   \n ").isEmpty)
        XCTAssertTrue(SearchQuery(parsing: "iso:").isEmpty, "a known field with no value yet is ignored while typing")
        XCTAssertTrue(SearchQuery(parsing: "\"\"").isEmpty)
    }

    func testUnknownFieldIsPlainText() {
        let q = SearchQuery(parsing: "http:foo")
        XCTAssertEqual(q.terms, [.text("http:foo")])
        XCTAssertTrue(matches("http:foo", photo(1, "http:foo.jpg")))
        XCTAssertTrue(q.invalidTerms.isEmpty)
    }

    // MARK: Numbers

    func testISOComparisons() {
        let m = meta(1, iso: 800)
        let p = photo(1)
        XCTAssertTrue(matches("iso:800", p, m))
        XCTAssertFalse(matches("iso:801", p, m))
        XCTAssertTrue(matches("iso:>=800", p, m))
        XCTAssertFalse(matches("iso:>800", p, m), "strictly greater")
        XCTAssertTrue(matches("iso:>799", p, m))
        XCTAssertTrue(matches("iso:<=800", p, m))
        XCTAssertFalse(matches("iso:<800", p, m))
        XCTAssertTrue(matches("iso:=800", p, m))
        XCTAssertTrue(matches("iso:400..800", p, m), "inclusive upper bound")
        XCTAssertTrue(matches("iso:800..1600", p, m), "inclusive lower bound")
        XCTAssertFalse(matches("iso:801..1600", p, m))
        XCTAssertFalse(matches("iso:>200", photo(2), nil), "no camera data: never matches")
        XCTAssertFalse(matches("iso:>200", photo(3), meta(3)), "a row with no ISO: never matches")
    }

    func testApertureAcceptsFPrefixesAndToleratesRounding() {
        let p = photo(1)
        let m = meta(1, aperture: 2.79999)
        XCTAssertTrue(matches("aperture:2.8", p, m))
        XCTAssertTrue(matches("aperture:f2.8", p, m))
        XCTAssertTrue(matches("aperture:F/2.8", p, m))
        XCTAssertFalse(matches("aperture:f4", p, m))
        XCTAssertTrue(matches("aperture:<=f4", p, m))
        XCTAssertTrue(matches("aperture:f2..f4", p, m))
        XCTAssertFalse(matches("aperture:>f2.8", p, m), "ordering comparisons are exact: 2.79999 is not greater than 2.8")
    }

    func testShutterFractionsAndSeconds() {
        let p = photo(1)
        let m = meta(1, shutter: 0.004)
        XCTAssertTrue(matches("shutter:1/250", p, m))
        XCTAssertFalse(matches("shutter:1/500", p, m))
        XCTAssertTrue(matches("shutter:<1/100", p, m), "faster than 1/100")
        XCTAssertTrue(matches("shutter:>1/1000", p, m))
        XCTAssertTrue(matches("shutter:>=0.004", p, m))
        XCTAssertTrue(matches("shutter:2s", p, meta(1, shutter: 2)))
        XCTAssertTrue(matches("shutter:1/250..1/100", p, m))
        XCTAssertFalse(matches("shutter:0", p, m), "zero is not a valid shutter value")
        XCTAssertEqual(SearchQuery(parsing: "shutter:1/0").invalidTerms, ["shutter:1/0"])
    }

    func testFocalLength() {
        let p = photo(1)
        let m = meta(1, focal: 50)
        XCTAssertTrue(matches("focal:50", p, m))
        XCTAssertTrue(matches("focal:50mm", p, m))
        XCTAssertTrue(matches("focal:>=35", p, m))
        XCTAssertFalse(matches("focal:>50", p, m))
        XCTAssertTrue(matches("focal:24..70", p, m))
    }

    func testRatingUsesThePhotoAndNeedsNoMetadata() {
        XCTAssertTrue(matches("rating:3", photo(1, rating: 3)))
        XCTAssertFalse(matches("rating:3", photo(1, rating: 4)))
        XCTAssertTrue(matches("rating:>3", photo(1, rating: 4)))
        XCTAssertFalse(matches("rating:>3", photo(1, rating: 3)))
        XCTAssertTrue(matches("rating:>=3", photo(1, rating: 3)))
        XCTAssertTrue(matches("rating:0", photo(1, rating: 0)))
        XCTAssertTrue(matches("rating:2..4", photo(1, rating: 4)))
    }

    // MARK: Dates

    func testDatePeriodsAndEdges() {
        let p = photo(1)
        let m = meta(1, date: "2023:03:14 09:30:15")
        XCTAssertTrue(matches("date:2023", p, m))
        XCTAssertTrue(matches("date:2023-03", p, m))
        XCTAssertTrue(matches("date:2023-03-14", p, m))
        XCTAssertTrue(matches("date:2023/03/14", p, m), "slashes work too")
        XCTAssertFalse(matches("date:2023-04", p, m))
        XCTAssertFalse(matches("date:2022", p, m))
        XCTAssertFalse(matches("date:2023-03-15", p, m))
        // `>` is AFTER the period; `>=` from its start; `<` before its start; `<=` through its end.
        XCTAssertTrue(matches("date:>2023-02", p, m))
        XCTAssertFalse(matches("date:>2023-03", p, m), "March is not after March")
        XCTAssertTrue(matches("date:>=2023-03", p, m))
        XCTAssertFalse(matches("date:<2023-03", p, m))
        XCTAssertTrue(matches("date:<=2023-03", p, m))
        XCTAssertTrue(matches("date:<2023-04", p, m))
        XCTAssertTrue(matches("date:<=2023-03-14", p, m))
        XCTAssertFalse(matches("date:<2023-03-14", p, m))
        XCTAssertTrue(matches("date:2023-01..2023-06", p, m))
        XCTAssertTrue(matches("date:2023-03..2023-03", p, m), "a one-period range is that period")
        XCTAssertFalse(matches("date:2023-04..2023-06", p, m))
        XCTAssertFalse(matches("date:2023", photo(2), nil), "no capture date: never matches")
    }

    func testDateBoundariesAreExact() {
        let p = photo(1)
        XCTAssertTrue(matches("date:2023-03-31", p, meta(1, date: "2023:03:31 23:59:59")), "last second of the day")
        XCTAssertFalse(matches("date:2023-03-31", p, meta(1, date: "2023:04:01 00:00:00")), "first second of the next day")
        XCTAssertTrue(matches("date:2023-04-01", p, meta(1, date: "2023:04:01 00:00:00")))
        XCTAssertTrue(matches("date:2023-02-28", p, meta(1, date: "2023:02:28 12:00:00")))
        XCTAssertTrue(matches("date:2024-02-29", p, meta(1, date: "2024:02:29 12:00:00")), "leap day")
        XCTAssertTrue(matches("date:2023", p, meta(1, date: "2023:12:31 23:59:59")))
        XCTAssertFalse(matches("date:2023", p, meta(1, date: "2024:01:01 00:00:00")))
    }

    func testDateComparisonsAtTheExactBoundaryInstants() {
        let p = photo(1)
        let firstOfMarch = meta(1, date: "2023:03:01 00:00:00")
        let lastOfMarch = meta(1, date: "2023:03:31 23:59:59")
        let firstOfApril = meta(1, date: "2023:04:01 00:00:00")
        // `>` is AFTER the whole period (the first instant of April counts), `<=` is THROUGH it (April 1st 00:00:00 does not).
        XCTAssertTrue(matches("date:>2023-03", p, firstOfApril))
        XCTAssertFalse(matches("date:>2023-03", p, lastOfMarch))
        XCTAssertFalse(matches("date:<=2023-03", p, firstOfApril))
        XCTAssertTrue(matches("date:<=2023-03", p, lastOfMarch))
        // `>=` starts AT the period's first instant, `<` is strictly before it.
        XCTAssertTrue(matches("date:>=2023-03", p, firstOfMarch))
        XCTAssertFalse(matches("date:<2023-03", p, firstOfMarch))
        XCTAssertTrue(matches("date:<2023-03", p, meta(1, date: "2023:02:28 23:59:59")))
        // `=` is the period itself, like the bare form.
        XCTAssertTrue(matches("date:=2023-03", p, meta(1, date: "2023:03:14 09:30:15")))
        XCTAssertTrue(matches("date:=2023-03", p, firstOfMarch))
        XCTAssertFalse(matches("date:=2023-03", p, firstOfApril))
        XCTAssertTrue(matches("date:=2023", p, meta(1, date: "2023:12:31 23:59:59")))
        XCTAssertFalse(matches("date:=2023-03-14", p, meta(1, date: "2023:03:15 00:00:00")))
        // A day-level boundary too.
        XCTAssertTrue(matches("date:>2023-03-14", p, meta(1, date: "2023:03:15 00:00:00")))
        XCTAssertFalse(matches("date:>2023-03-14", p, meta(1, date: "2023:03:14 23:59:59")))
    }

    func testBadDatesAreInvalid() {
        for bad in ["date:2023-13", "date:2023-02-30", "date:23", "date:abc", "date:2023-03-14-01", "date:2023-00", "date:..2023", "date:2023.."] {
            let q = SearchQuery(parsing: bad)
            XCTAssertEqual(q.invalidTerms, [bad], bad)
            XCTAssertFalse(matches(bad, photo(1), meta(1, date: "2023:03:14 09:30:15")), bad)
        }
            }

    // MARK: Text fields

    func testCameraMatchesMakeModelOrTheJoinedName() {
        let p = photo(1)
        let m = meta(1, make: "NIKON CORPORATION", model: "NIKON D610")
        XCTAssertTrue(matches("camera:d610", p, m))
        XCTAssertTrue(matches("camera:nikon", p, m))
        XCTAssertTrue(matches("camera:\"nikon d610\"", p, m))
        XCTAssertTrue(matches("camera:corporation", p, m), "the raw make is searchable too")
        XCTAssertFalse(matches("camera:canon", p, m))
        XCTAssertFalse(matches("camera:nikon", p, nil))
    }

    func testLensKeywordAndNameFields() {
        let p = photo(1, "Beach Day.jpg")
        XCTAssertTrue(matches("lens:50mm", p, meta(1, lens: "AF-S NIKKOR 50mm f/1.8G")))
        XCTAssertFalse(matches("lens:85", p, meta(1, lens: "AF-S NIKKOR 50mm f/1.8G")))
        XCTAssertFalse(matches("lens:50", p, nil))
        XCTAssertTrue(matches("keyword:moun", p, keywords: ["Mountains"]))
        XCTAssertFalse(matches("keyword:beach", p, keywords: ["Mountains"]), "keyword: does not look at the filename")
        XCTAssertTrue(matches("name:beach", p))
        XCTAssertFalse(matches("name:mountain", p, keywords: ["Mountains"]), "name: does not look at keywords")
    }

    func testTokenizerQuoteEdgeCases() {
        XCTAssertEqual(SearchQuery(parsing: "ab\"c d\"e").terms, [.text("abc de")], "a quote in the middle of a token")
        XCTAssertEqual(SearchQuery(parsing: "foo \"bar baz").terms, [.text("foo"), .text("bar baz")], "an unbalanced quote runs to the end")
        XCTAssertEqual(SearchQuery(parsing: "\"iso:>800\"").terms, [.text("iso:>800")], "a token that begins with a quote is a phrase")
        XCTAssertEqual(SearchQuery(parsing: "iso:>800").terms.count, 1)
        XCTAssertEqual(SearchQuery(parsing: "日本語 カメラ").terms, [.text("日本語"), .text("カメラ")])
        XCTAssertTrue(matches("日本語", photo(1, "日本語の写真.jpg")))
    }

    func testOperatorOnlyValuesAreIgnoredWhileTyping() {
        for partial in ["iso:>", "iso:>=", "iso:<", "iso:<=", "iso:=", "date:>", "iso:.."] {
            XCTAssertTrue(SearchQuery(parsing: partial).isEmpty, partial)
        }
        XCTAssertFalse(SearchQuery(parsing: "iso:>8").isEmpty)
    }

    func testNumericRangesAcceptEitherOrderButReversedDatesStayInvalid() {
        let p = photo(1)
        XCTAssertTrue(matches("shutter:1/30..1/250", p, meta(1, shutter: 0.004)), "slow-to-fast")
        XCTAssertTrue(matches("shutter:1/250..1/30", p, meta(1, shutter: 0.004)))
        XCTAssertTrue(matches("iso:1600..400", p, meta(1, iso: 800)))
        XCTAssertEqual(SearchQuery(parsing: "date:2023-06..2023-01").invalidTerms.count, 1)
        // Adjacent periods: the start of the first equals the exclusive end of the second, an empty interval.
        for reversed in ["date:2023-04..2023-03", "date:2024..2023", "date:2023-03-15..2023-03-14"] {
            XCTAssertEqual(SearchQuery(parsing: reversed).invalidTerms, [reversed], reversed)
        }
        XCTAssertTrue(SearchQuery(parsing: "date:2023-03..2023-04").invalidTerms.isEmpty, "the forward order is valid")
    }

    func testMalformedDatePartsAreInvalid() {
        for bad in ["date:2023--03", "date:2023-", "date:-2023", "date:2023-003", "date:2023-03-014", "date:2023-3-1x"] {
            XCTAssertEqual(SearchQuery(parsing: bad).invalidTerms, [bad], bad)
        }
        for good in ["date:2023-3", "date:2023-3-4", "date:2023-03-04"] {
            XCTAssertTrue(SearchQuery(parsing: good).invalidTerms.isEmpty, good)
        }
    }

    func testQuotedFieldValuesKeepSpaces() {
        let q = SearchQuery(parsing: "lens:\"AF-S NIKKOR\" iso:>100")
        XCTAssertEqual(q.terms.count, 2)
        XCTAssertTrue(matches("lens:\"AF-S NIKKOR\"", photo(1), meta(1, lens: "AF-S NIKKOR 50mm")))
    }

    // MARK: Flags and labels

    func testFlagAndLabelFields() {
        XCTAssertTrue(matches("flag:pick", photo(1, flag: .picked)))
        XCTAssertTrue(matches("flag:picked", photo(1, flag: .picked)))
        XCTAssertFalse(matches("flag:pick", photo(1, flag: .rejected)))
        XCTAssertTrue(matches("flag:reject", photo(1, flag: .rejected)))
        XCTAssertTrue(matches("flag:none", photo(1)))
        XCTAssertFalse(matches("flag:none", photo(1, flag: .picked)))
        XCTAssertTrue(matches("label:red", photo(1, label: .red)))
        XCTAssertTrue(matches("label:BLUE", photo(1, label: .blue)))
        XCTAssertFalse(matches("label:red", photo(1, label: .blue)))
        XCTAssertTrue(matches("label:none", photo(1)))
        XCTAssertEqual(SearchQuery(parsing: "flag:maybe").invalidTerms, ["flag:maybe"])
        XCTAssertEqual(SearchQuery(parsing: "label:pink").invalidTerms, ["label:pink"])
    }

    // MARK: Invalid values and combinations

    func testInvalidValuesMatchNothingAndAreReported() {
        for bad in ["iso:abc", "iso:>x", "iso:-5", "aperture:f", "focal:0", "rating:high", "iso:800..", "iso:..800", "aperture:2...4"] {
            let q = SearchQuery(parsing: bad)
            XCTAssertEqual(q.invalidTerms, [bad], bad)
            XCTAssertFalse(matches(bad, photo(1, rating: 3), meta(1, iso: 800, focal: 50, aperture: 2.8)), bad)
        }
    }

    func testTermsAreCombinedWithAnd() {
        let p = photo(1, "Trip.jpg", rating: 4, flag: .picked)
        let m = meta(1, iso: 1600, make: "NIKON CORPORATION", model: "NIKON D610", date: "2023:03:14 09:30:15")
        XCTAssertTrue(matches("trip camera:d610 iso:>800 date:2023-03 rating:>3 flag:pick", p, m))
        XCTAssertFalse(matches("trip camera:d610 iso:>800 date:2023-03 rating:>3 flag:reject", p, m))
        XCTAssertFalse(matches("trip camera:d610 iso:>3200", p, m))
        XCTAssertFalse(matches("trip iso:abc camera:d610", p, m), "one invalid term makes the whole query match nothing")
    }

    func testFieldNamesAreCaseInsensitive() {
        XCTAssertTrue(matches("ISO:>100", photo(1), meta(1, iso: 200)))
        XCTAssertTrue(matches("Camera:NIKON", photo(1), meta(1, make: "Nikon")))
    }

    func testUsesCameraData() {
        XCTAssertTrue(SearchQuery(parsing: "iso:>100").usesCameraData)
        XCTAssertTrue(SearchQuery(parsing: "camera:x lens:y date:2023").usesCameraData)
        XCTAssertFalse(SearchQuery(parsing: "rating:3 flag:pick label:red keyword:x name:y plain").usesCameraData)
    }
}
