import Foundation

/// Which order the Library grid displays photos in. `.dateOldest` is the
/// default — deliberately matching `CatalogDatabase.allPhotos()`/
/// `photos(inCollection:)`'s own existing DB-level `ORDER BY importedAt,
/// id` (ascending), so nothing changes for anyone not using the new sort
/// picker; the other three are opt-in.
enum LibrarySortOption: String, CaseIterable, Identifiable, Sendable {
    case dateOldest, dateNewest, ratingHighToLow, nameAZ, captureNewest, captureOldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateOldest: return "Oldest First"
        case .dateNewest: return "Newest First"
        case .ratingHighToLow: return "Highest Rated"
        case .nameAZ: return "Name (A–Z)"
        case .captureNewest: return "Capture Date, Newest"
        case .captureOldest: return "Capture Date, Oldest"
        }
    }
}

/// Which pick/reject states the Library grid shows. `.all` is the default:
/// hiding rejects by default would silently hide photos the user has.
enum LibraryFlagFilter: String, CaseIterable, Identifiable, Sendable, Codable {
    case all, picked, unflagged, rejected, notRejected

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "All Flags"
        case .picked: return "Picked"
        case .unflagged: return "Unflagged"
        case .rejected: return "Rejected"
        case .notRejected: return "Hide Rejected"
        }
    }

    func matches(_ status: FlagStatus) -> Bool {
        switch self {
        case .all: return true
        case .picked: return status == .picked
        case .unflagged: return status == .none
        case .rejected: return status == .rejected
        case .notRejected: return status != .rejected
        }
    }
}

/// Which color labels the Library grid shows. `.all` is the default.
enum LibraryLabelFilter: String, CaseIterable, Identifiable, Sendable, Codable {
    case all, unlabeled, red, yellow, green, blue, purple

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "All Labels"
        case .unlabeled: return "No Label"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    func matches(_ label: ColorLabel) -> Bool {
        switch self {
        case .all: return true
        case .unlabeled: return label == .none
        case .red: return label == .red
        case .yellow: return label == .yellow
        case .green: return label == .green
        case .blue: return label == .blue
        case .purple: return label == .purple
        }
    }
}

/// Pure, SwiftUI/GRDB-independent Library grid refinement — sort + rating/
/// flag/label/filename filtering, applied entirely in memory to whatever source
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
    ///     `filename` or any keyword name (see `keywordNamesByPhotoID`), trimmed of leading/trailing whitespace first; an
    ///     empty (or whitespace-only) string means no search filter.
    ///   - labelFilter: which color label(s) to keep; `.all` (the default)
    ///     means no label filter.
    ///   - keywordFilter: the keyword ids a photo must carry (ANY of them
    ///     matches); `nil` (the default) means no keyword filter. A photo
    ///     with no entry in `keywordIDsByPhotoID` carries none.
    ///   - infoByPhotoID: each photo's Library info (a virtual copy under its own id), for the plain-text and `title:`/`caption:`/`creator:`/`copyright:` search terms.
    ///   - personFilter: keep only photos with a face assigned to this person (`nil`: no person filter).
    ///   - keywordNamesByPhotoID: each photo's keyword display names, so
    ///     the search box also matches keywords (substring, case-insensitive,
    ///     like filenames). Only consulted when `searchText` is non-empty.
    static func apply(
        to photos: [Photo], sort: LibrarySortOption,
        minimumRating: Int, flagFilter: LibraryFlagFilter, searchText: String,
        labelFilter: LibraryLabelFilter = .all,
        keywordFilter: Set<Int64>? = nil,
        keywordIDsByPhotoID: [Int64: Set<Int64>] = [:],
        keywordNamesByPhotoID: [Int64: [String]] = [:],
        personFilter: Int64? = nil,
        personIDsByPhotoID: [Int64: Set<Int64>] = [:],
        metadataByPhotoID: [Int64: PhotoMetadata] = [:],
        infoByPhotoID: [Int64: PhotoInfo] = [:]
    ) -> [Photo] {
        var result = photos
        if let personFilter {
            // A photo with no entry has no assigned face: it is never "a photo of" anyone.
            result = result.filter { photo in photo.id.flatMap { personIDsByPhotoID[$0] }?.contains(personFilter) == true }
        }
        if let keywordFilter {
            result = result.filter { photo in
                guard let id = photo.id, let own = keywordIDsByPhotoID[id] else { return false }
                return !own.isDisjoint(with: keywordFilter)
            }
        }
        if labelFilter != .all {
            result = result.filter { labelFilter.matches($0.colorLabel) }
        }
        if flagFilter != .all {
            result = result.filter { flagFilter.matches($0.flagStatus) }
        }
        if minimumRating > 0 {
            result = result.filter { $0.rating >= minimumRating }
        }
        let query = SearchQuery(parsing: searchText)
        if !query.isEmpty {
            result = result.filter { photo in
                let id = photo.id
                return query.matches(
                    photo, metadata: id.flatMap { metadataByPhotoID[$0] },
                    keywordNames: id.flatMap { keywordNamesByPhotoID[$0] } ?? [],
                    info: id.flatMap { infoByPhotoID[$0] }
                )
            }
        }
        switch sort {
        case .dateOldest:
            result.sort { $0.importedAt < $1.importedAt }
        case .dateNewest:
            result.sort { $0.importedAt > $1.importedAt }
        case .ratingHighToLow:
            result.sort { $0.rating > $1.rating }
        case .captureNewest, .captureOldest:
            // Photos with no cached capture date go LAST in both directions (they have no place on the timeline).
            let newestFirst = sort == .captureNewest
            func capture(_ photo: Photo) -> Double? { photo.id.flatMap { metadataByPhotoID[$0]?.captureDate } }
            result.sort { a, b in
                switch (capture(a), capture(b)) {
                case let (x?, y?): return x == y ? (a.id ?? 0) < (b.id ?? 0) : (newestFirst ? x > y : x < y)
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return (a.id ?? 0) < (b.id ?? 0)
                }
            }
        case .nameAZ:
            // `localizedStandardCompare` (not `<`) so numeric runs sort
            // naturally — "Photo 2" before "Photo 10" — matching Finder's
            // own filename ordering convention, not a plain lexical sort.
            result.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
        return result
    }
}

/// Which of the Library's filters are away from their defaults. SORT is deliberately not a filter (changing the order hides nothing), so it
/// never counts; a whitespace-only search is no search. Drives the filter bar's "active" cue and its Clear button.
struct LibraryFilterState: Equatable {
    var minimumRating = 0
    var flagFilter = LibraryFlagFilter.all
    var labelFilter = LibraryLabelFilter.all
    var keywordFilterID: Int64?
    var searchText = ""
    var personFilterID: Int64?

    var isRatingActive: Bool { minimumRating > 0 }
    var isFlagActive: Bool { flagFilter != .all }
    var isLabelActive: Bool { labelFilter != .all }
    var isKeywordActive: Bool { keywordFilterID != nil }
    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isPersonActive: Bool { personFilterID != nil }

    var activeCount: Int {
        [isRatingActive, isFlagActive, isLabelActive, isKeywordActive, isSearchActive, isPersonActive].filter { $0 }.count
    }
    var isActive: Bool { activeCount > 0 }
}

