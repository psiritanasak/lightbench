import Foundation

/// Which order the Library grid displays photos in. `.dateOldest` is the
/// default — deliberately matching `CatalogDatabase.allPhotos()`/
/// `photos(inCollection:)`'s own existing DB-level `ORDER BY importedAt,
/// id` (ascending), so nothing changes for anyone not using the new sort
/// picker; the other three are opt-in.
enum LibrarySortOption: String, CaseIterable, Identifiable, Sendable {
    case dateOldest, dateNewest, ratingHighToLow, nameAZ

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateOldest: return "Oldest First"
        case .dateNewest: return "Newest First"
        case .ratingHighToLow: return "Highest Rated"
        case .nameAZ: return "Name (A–Z)"
        }
    }
}

/// Pure, SwiftUI/GRDB-independent Library grid refinement — sort + rating/
/// flag/filename filtering, applied entirely in memory to whatever source
/// set `CatalogModel.photos` already holds (the sidebar's Collection/Folder
/// selection). Extracted as a standalone type specifically so this logic
/// gets direct unit test coverage, matching this project's established
/// pattern for pure UI-layer logic (`CropAspectMath`, `CompareLayout`,
/// `ZoomPanGeometry`) — even though this one lives in `Sources/Catalog`
/// rather than `Sources/UI`, since it operates on `Photo` (a Catalog-module
/// type) and has no UI dependency at all.
enum LibraryFilterSort {
    /// - Parameters:
    ///   - minimumRating: a THRESHOLD ("N stars and up"), not an exact
    ///     match — matches the Photos/Lightroom convention. `0` means no
    ///     rating filter at all (includes unrated photos).
    ///   - searchText: case-insensitive substring match against
    ///     `filename`, trimmed of leading/trailing whitespace first; an
    ///     empty (or whitespace-only) string means no search filter.
    static func apply(
        to photos: [Photo], sort: LibrarySortOption,
        minimumRating: Int, flaggedOnly: Bool, searchText: String
    ) -> [Photo] {
        var result = photos
        if flaggedOnly {
            result = result.filter(\.isFlagged)
        }
        if minimumRating > 0 {
            result = result.filter { $0.rating >= minimumRating }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.filename.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .dateOldest:
            result.sort { $0.importedAt < $1.importedAt }
        case .dateNewest:
            result.sort { $0.importedAt > $1.importedAt }
        case .ratingHighToLow:
            result.sort { $0.rating > $1.rating }
        case .nameAZ:
            // `localizedStandardCompare` (not `<`) so numeric runs sort
            // naturally — "Photo 2" before "Photo 10" — matching Finder's
            // own filename ordering convention, not a plain lexical sort.
            result.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
        return result
    }
}
