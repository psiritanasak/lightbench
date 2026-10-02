import Foundation
import GRDB

/// What a Smart Collection keeps: the Library filter-bar criteria that can be saved. `.empty` restricts nothing.
/// v1 scope: minimum rating, flag, colour label and ONE keyword (referenced by `Keyword.nameKey`).
struct SmartCollectionCriteria: Equatable, Sendable {
    var minimumRating: Int = 0
    var flag: LibraryFlagFilter = .all
    var label: LibraryLabelFilter = .all
    /// `Keyword.nameKey` of the required keyword, or nil. Stored as the key (not the row id) so the criterion
    /// survives the keyword row being recreated and never dangles into a foreign key.
    var keywordKey: String?
    /// True when a stored criterion was PRESENT but not understood by this build (an unknown flag/label raw value, a
    /// wrongly typed field — e.g. written by a newer build). Such a collection matches NOTHING rather than silently
    /// broadening to "no restriction" (a saved "Rejected only" must never show every photo). Never persisted: a
    /// criterion this build rewrites is, by construction, one it understands.
    var hasUnrecognizedCriterion = false

    static let empty = SmartCollectionCriteria()

    /// True when the criteria restrict nothing (a saved set like that would just be "All Photos").
    var isEmpty: Bool { self == .empty }

    /// The keyword-id set `LibraryFilterSort.apply(keywordFilter:)` expects: nil when there is no keyword
    /// criterion, and an EMPTY set (matches nothing) when the criterion names a keyword that no longer exists — a
    /// criterion on a deleted keyword must never silently turn into "match everything".
    func keywordFilter(resolving keywords: [Keyword]) -> Set<Int64>? {
        guard let keywordKey else { return nil }
        let ids = keywords.filter { $0.nameKey == keywordKey }.compactMap(\.id)
        return Set(ids)
    }

    /// `photos` reduced to those matching, via the same pure filter the filter bar uses (no search, no re-sort).
    func apply(to photos: [Photo], keywords: [Keyword], keywordIDsByPhotoID: [Int64: Set<Int64>]) -> [Photo] {
        if hasUnrecognizedCriterion { return [] }
        guard !isEmpty else { return photos }
        let kept = Set(LibraryFilterSort.apply(
            to: photos, sort: .dateOldest, minimumRating: minimumRating, flagFilter: flag, searchText: "",
            labelFilter: label, keywordFilter: keywordFilter(resolving: keywords), keywordIDsByPhotoID: keywordIDsByPhotoID
        ).compactMap(\.id))
        // `apply` re-sorts; filtering the ORIGINAL array keeps the caller's order, so this stays a pure FILTER.
        return photos.filter { $0.id.map(kept.contains) ?? false }
    }
}

/// Schema-tolerant persistence, per field (the `ExportSettings` pattern): a missing or unknown value decodes to
/// "no restriction" for that field only.
extension SmartCollectionCriteria: Codable {
    private enum CodingKeys: String, CodingKey { case minimumRating, flag, label, keywordKey }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A MISSING (or null) key means "no restriction" for that field; a PRESENT but undecodable one means a
        // criterion this build does not understand, which must match nothing (see `hasUnrecognizedCriterion`).
        func decoded<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard container.contains(key), (try? container.decodeNil(forKey: key)) == false else { return nil }
            do { return try container.decode(type, forKey: key) } catch { hasUnrecognizedCriterion = true; return nil }
        }
        minimumRating = min(max(decoded(Int.self, .minimumRating) ?? 0, 0), 5)
        flag = decoded(LibraryFlagFilter.self, .flag) ?? .all
        label = decoded(LibraryLabelFilter.self, .label) ?? .all
        keywordKey = decoded(String.self, .keywordKey)
    }
}

/// A named, saved set of filter criteria shown in the sidebar; its contents are computed, never stored.
struct SmartCollection: Codable, Equatable, Identifiable, Sendable {
    var id: Int64?
    var name: String
    var criteria: SmartCollectionCriteria
    var createdAt: Date
}

extension SmartCollection: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension SmartCollection: FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "smart_collection"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let criteria = Column(CodingKeys.criteria)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

enum SmartCollectionError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the smart collection a name."
        case .duplicateName(let name): return "A smart collection named \"\(name)\" already exists."
        case .notFound: return "That smart collection no longer exists."
        }
    }
}
