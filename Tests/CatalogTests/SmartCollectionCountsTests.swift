import XCTest
@testable import PhotoApp

/// `SmartCollectionCounts` must equal what `CatalogModel.smartCollectionSourcePhotos` would show for each collection.
final class SmartCollectionCountsTests: XCTestCase {
    private func photo(_ id: Int64, rating: Int = 0, flag: FlagStatus = .none, label: ColorLabel = .none, master: Int64? = nil) -> Photo {
        var p = Photo(id: id, path: "/tmp/\(id).jpg", filename: "\(id).jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: Double(id)))
        p.rating = rating
        p.flagStatus = flag
        p.colorLabel = label
        if let master { p.masterId = master; p.versionKey = "v\(id)" }
        return p
    }

    private func smart(_ id: Int64, _ criteria: SmartCollectionCriteria) -> SmartCollection {
        SmartCollection(id: id, name: "s\(id)", criteria: criteria, createdAt: Date())
    }

    private func meta(_ id: Int64, iso: Int) -> PhotoMetadata {
        PhotoMetadata(photoId: id, fileSize: 1, mtime: 1, readerRevision: PhotoMetadata.currentReaderRevision, iso: iso, scannedAt: Date())
    }

    /// The reference: what the model does for a selected smart collection.
    private func reference(_ s: SmartCollection, photos: [Photo], keywords: [Keyword], links: [Int64: Set<Int64>],
                           metadata: [Int64: PhotoMetadata], info: [Int64: PhotoInfo]) -> Int {
        let hasQuery = !s.criteria.searchQuery.isEmpty
        let names = Dictionary(uniqueKeysWithValues: keywords.compactMap { k in k.id.map { ($0, k.name) } })
        return s.criteria.apply(
            to: photos, keywords: keywords, keywordIDsByPhotoID: links,
            keywordNamesByPhotoID: hasQuery ? links.mapValues { $0.compactMap { names[$0] } } : [:],
            metadataByPhotoID: CatalogModel.inheritingFromMasters(metadata, photos: photos),
            infoByPhotoID: hasQuery ? CatalogModel.inheritingFromMasters(info, photos: photos) : [:]
        ).count
    }

    func testCountsEqualTheModelsFilterForEveryCriterionKind() {
        let photos = [photo(1, rating: 5), photo(2, rating: 2, flag: .picked), photo(3, rating: 5, label: .red),
                      photo(4, rating: 4, flag: .rejected), photo(5, rating: 5, master: 1), photo(6, rating: 5, master: 3)]
        let sky = Keyword(id: 10, name: "Sky", nameKey: KeywordName.key(for: "Sky"), createdAt: Date())
        let links: [Int64: Set<Int64>] = [1: [10], 3: [10], 4: [10]]
        let metadata: [Int64: PhotoMetadata] = [1: meta(1, iso: 3200), 2: meta(2, iso: 100), 3: meta(3, iso: 3200)]
        let info: [Int64: PhotoInfo] = [1: PhotoInfo(title: "Harbour", caption: "", creator: "", copyright: "")]

        var rating = SmartCollectionCriteria(); rating.minimumRating = 4
        var flag = SmartCollectionCriteria(); flag.flag = .picked
        var label = SmartCollectionCriteria(); label.label = .red
        var keyword = SmartCollectionCriteria(); keyword.keywordKey = sky.nameKey
        var gone = SmartCollectionCriteria(); gone.keywordKey = KeywordName.key(for: "Gone")
        var unknown = SmartCollectionCriteria(); unknown.hasUnrecognizedCriterion = true
        var iso = SmartCollectionCriteria(); iso.searchQuery = "iso:>1600"
        var title = SmartCollectionCriteria(); title.searchQuery = "harbour"
        var kwText = SmartCollectionCriteria(); kwText.searchQuery = "sky"
        var combined = SmartCollectionCriteria(); combined.minimumRating = 5; combined.searchQuery = "iso:>1600"
        let all = [SmartCollectionCriteria.empty, rating, flag, label, keyword, gone, unknown, iso, title, kwText, combined]
        let collections = all.enumerated().map { smart(Int64($0.offset + 1), $0.element) }

        let counts = SmartCollectionCounts.counts(
            smartCollections: collections, photos: photos, keywords: [sky], keywordIDsByPhotoID: links,
            metadataByPhotoID: metadata, infoByPhotoID: info)
        XCTAssertEqual(counts.count, collections.count)
        for s in collections {
            XCTAssertEqual(counts[s.id ?? 0], reference(s, photos: photos, keywords: [sky], links: links, metadata: metadata, info: info),
                           "mismatch for \(s.criteria.summary)")
        }
        XCTAssertEqual(counts[1], photos.count, "empty criteria count every photo")
        XCTAssertEqual(counts[6], 0, "a deleted keyword matches nothing")
        XCTAssertEqual(counts[7], 0, "an unrecognised criterion matches nothing")
        XCTAssertEqual(counts[8], 4, "ISO search: photos 1 and 3 and their virtual copies 5 and 6 (inheriting the master's data)")
        XCTAssertEqual(counts[9], 2, "info search: photo 1 and its copy 5")
    }

    func testNoSmartCollectionsGivesAnEmptyMap() {
        XCTAssertEqual(SmartCollectionCounts.counts(smartCollections: [], photos: [photo(1)], keywords: [], keywordIDsByPhotoID: [:],
                                                    metadataByPhotoID: [:], infoByPhotoID: [:]), [:])
    }

    /// Regression guard only: it asserts no time limit and says nothing about a real catalog.
    func testCountingSixHundredSyntheticPhotosMeasure() {
        let photos = (1...600).map { photo(Int64($0), rating: $0 % 6, flag: $0 % 7 == 0 ? .picked : .none) }
        var metadata: [Int64: PhotoMetadata] = [:]
        for p in photos { if let id = p.id { metadata[id] = meta(id, iso: 100 * Int(id % 40)) } }
        var criteria: [SmartCollectionCriteria] = []
        for i in 0..<4 { var c = SmartCollectionCriteria(); c.minimumRating = i + 1; criteria.append(c) }
        var search = SmartCollectionCriteria(); search.searchQuery = "iso:>1600"; criteria.append(search)
        let collections = criteria.enumerated().map { smart(Int64($0.offset + 1), $0.element) }
        measure {
            _ = SmartCollectionCounts.counts(smartCollections: collections, photos: photos, keywords: [], keywordIDsByPhotoID: [:],
                                             metadataByPhotoID: metadata, infoByPhotoID: [:])
        }
    }
}
