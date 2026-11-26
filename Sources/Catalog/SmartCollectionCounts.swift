import Foundation

/// How many photos each smart collection holds, for the sidebar. Pure and `nonisolated`, so it can run off the main thread.
/// Every count equals `CatalogModel.smartCollectionSourcePhotos.count` for that collection over the same photos: an
/// unrecognised criterion gives 0, empty criteria give every photo, a criterion on a deleted keyword gives 0, and a virtual
/// copy inherits its master's camera data and info for search terms.
enum SmartCollectionCounts {
    nonisolated static func counts(
        smartCollections: [SmartCollection], photos: [Photo], keywords: [Keyword],
        keywordIDsByPhotoID: [Int64: Set<Int64>], metadataByPhotoID: [Int64: PhotoMetadata],
        infoByPhotoID: [Int64: PhotoInfo],
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [Int64: Int] {
        guard !smartCollections.isEmpty else { return [:] }
        let anySearch = smartCollections.contains { !$0.criteria.searchQuery.isEmpty }
        // Built once, and only when some collection has a saved search (the only reader of any of the three).
        var keywordNames: [Int64: [String]] = [:]
        var metadata: [Int64: PhotoMetadata] = [:]
        var info: [Int64: PhotoInfo] = [:]
        if anySearch {
            let namesByID = Dictionary(uniqueKeysWithValues: keywords.compactMap { keyword in keyword.id.map { ($0, keyword.name) } })
            keywordNames = keywordIDsByPhotoID.mapValues { $0.compactMap { namesByID[$0] } }
            metadata = CatalogModel.inheritingFromMasters(metadataByPhotoID, photos: photos)
            info = CatalogModel.inheritingFromMasters(infoByPhotoID, photos: photos)
        }
        var result: [Int64: Int] = [:]
        for smart in smartCollections {
            if isCancelled() { return result } // partial: the caller discards a cancelled result
            guard let id = smart.id else { continue }
            let hasSearch = !smart.criteria.searchQuery.isEmpty
            result[id] = smart.criteria.apply(
                to: photos, keywords: keywords, keywordIDsByPhotoID: keywordIDsByPhotoID,
                keywordNamesByPhotoID: hasSearch ? keywordNames : [:],
                metadataByPhotoID: metadataByPhotoID.isEmpty ? [:] : (anySearch ? metadata : metadataByPhotoID),
                infoByPhotoID: hasSearch ? info : [:]
            ).count
        }
        return result
    }
}
