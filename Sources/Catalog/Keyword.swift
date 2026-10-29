import Foundation
import GRDB

/// A free-text tag that can be attached to any number of photos (Library keywords). `name` is the user's own
/// spelling; `nameKey` is what makes two spellings the same keyword (`KeywordName.key(for:)`).
struct Keyword: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: Int64?
    var name: String
    var nameKey: String
    var createdAt: Date
}

/// The join row between `Keyword` and `Photo` (composite primary key, no autoincrement id) — same shape as `CollectionPhoto`.
struct PhotoKeyword: Codable, Equatable, Hashable, Sendable {
    var keywordId: Int64
    var photoId: Int64
}

extension Keyword: FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "keyword"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let nameKey = Column(CodingKeys.nameKey)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension PhotoKeyword: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "photo_keyword"

    enum Columns {
        static let keywordId = Column(CodingKeys.keywordId)
        static let photoId = Column(CodingKeys.photoId)
    }
}

/// Pure keyword-text rules (no database, no UI).
enum KeywordName {
    static let maximumLength = 64
    static let maximumPerEntry = 20

    /// Maximum UTF-8 size of a stored name: `maximumLength` counts grapheme clusters, and one cluster can carry any
    /// number of combining marks, so the character cap alone does not bound the size.
    static let maximumBytes = 256

    /// A display name from raw typed text: control characters (category Cc only) and the meaningless invisibles
    /// U+200B/U+2060/U+FEFF dropped, whitespace runs collapsed to one space and trimmed, Unicode-normalized (NFC
    /// AFTER the filtering, so a removed character cannot leave a decomposed name), cut to `maximumLength`
    /// characters and `maximumBytes` bytes. `nil` when nothing is left.
    ///
    /// Deliberately KEEPS the other format characters (category Cf): ZWJ (U+200D) holds emoji families together,
    /// the tag characters U+E0020...E007F distinguish the England and Scotland flags, ZWNJ (U+200C) is part of
    /// Persian spelling, variation selectors choose text vs emoji presentation. Stripping them (an earlier draft
    /// used `CharacterSet.controlCharacters`, which also matches Cf) mangles valid text and falsely merges
    /// different keywords.
    static func normalize(_ raw: String) -> String? {
        let invisible: Set<UInt32> = [0x200B, 0x2060, 0xFEFF]
        let kept = raw.unicodeScalars.filter { scalar in
            // Checked BEFORE whitespace: Foundation counts U+200B as whitespace, which would keep it.
            if invisible.contains(scalar.value) { return false }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            return scalar.properties.generalCategory != .control
        }
        let collapsed = String(String.UnicodeScalarView(kept))
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        var name = String(collapsed.precomposedStringWithCanonicalMapping.prefix(maximumLength))
        while name.utf8.count > maximumBytes, !name.isEmpty { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The identity of a keyword: two names are the same keyword iff their keys are equal (Unicode-lowercased, then
    /// NFC). Deliberately NOT diacritic-insensitive ("resume" and "résumé" are different words) and NOT full case
    /// folding: `lowercased()` keeps "İstanbul"/"Istanbul", "Straße"/"STRASSE" and a Greek capital sigma vs final
    /// sigma apart — it errs toward separate keywords, never a false merge. The key depends on the OS's Unicode
    /// tables, so a much newer macOS could in theory key a rare character differently from an old row.
    static func key(for name: String) -> String {
        name.lowercased().precomposedStringWithCanonicalMapping
    }

    /// Splits typed text on commas, semicolons and newlines into normalized names, unique by `key(for:)` (first
    /// spelling wins, order kept), at most `maximumPerEntry`.
    static func parse(_ input: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for piece in input.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" || $0 == "\r" }) {
            guard let name = normalize(String(piece)), seen.insert(key(for: name)).inserted else { continue }
            names.append(name)
            if names.count == maximumPerEntry { break }
        }
        return names
    }
}

/// Why `CatalogDatabase.setKeywords` wrote nothing.
enum KeywordEditError: LocalizedError {
    case photoMissing

    var errorDescription: String? {
        switch self {
        case .photoMissing: return "the photo is no longer in the Library"
        }
    }
}
