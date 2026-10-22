import Foundation
import GRDB

/// The descriptive text the Library keeps for one photograph: title, caption, creator and copyright.
///
/// An empty string means "no value". The same type is what the export embedder and the XMP sidecar code receive,
/// so those layers never touch the catalog. Text rules (control characters, length caps) live in `InfoText`.
/// Info belongs to the photograph, not to an edit version: a virtual copy uses its master's info.
struct PhotoInfo: Equatable, Codable, Sendable {
    var title: String = ""
    var caption: String = ""
    var creator: String = ""
    var copyright: String = ""

    var isEmpty: Bool { title.isEmpty && caption.isEmpty && creator.isEmpty && copyright.isEmpty }

    /// This info with only the `fields` taken from `new` (each normalized by `InfoText`); the other fields are untouched.
    func applying(_ new: PhotoInfo, fields: InfoFields) -> PhotoInfo {
        var result = self
        if fields.contains(.title) { result.title = InfoText.normalize(new.title, field: .title) }
        if fields.contains(.caption) { result.caption = InfoText.normalize(new.caption, field: .caption) }
        if fields.contains(.creator) { result.creator = InfoText.normalize(new.creator, field: .creator) }
        if fields.contains(.copyright) { result.copyright = InfoText.normalize(new.copyright, field: .copyright) }
        return result
    }
}

/// Which of the four values an edit touches.
struct InfoFields: OptionSet, Sendable {
    let rawValue: Int
    static let title = InfoFields(rawValue: 1)
    static let caption = InfoFields(rawValue: 2)
    static let creator = InfoFields(rawValue: 4)
    static let copyright = InfoFields(rawValue: 8)
    static let all: InfoFields = [.title, .caption, .creator, .copyright]
}

extension PhotoInfo: FetchableRecord, TableRecord {
    static let databaseTableName = "photo_info"

    enum Columns {
        static let photoId = Column("photoId")
        static let title = Column(CodingKeys.title)
        static let caption = Column(CodingKeys.caption)
        static let creator = Column(CodingKeys.creator)
        static let copyright = Column(CodingKeys.copyright)
        static let updatedAt = Column("updatedAt")
    }
}

/// Pure info-text rules (no database, no UI); mirrors `KeywordName`.
enum InfoText {
    enum Field: CaseIterable { case title, caption, creator, copyright }

    /// Maximum length in characters (grapheme clusters).
    static func maximumLength(_ field: Field) -> Int {
        switch field {
        case .title, .creator: return 256
        case .copyright: return 512
        case .caption: return 2000
        }
    }

    /// Maximum UTF-8 size: the character cap alone does not bound it (one cluster can carry any number of combining marks).
    static func maximumBytes(_ field: Field) -> Int { maximumLength(field) * 4 }

    /// Clean text from raw typed text; "" when nothing is left.
    ///
    /// Control characters (category Cc) and U+200B/U+2060/U+FEFF are dropped; ZWJ/ZWNJ and the other format characters are KEPT
    /// (emoji sequences and Persian spelling need them; see `KeywordName.normalize`). Then NFC, trim, cut to the caps. A caption keeps
    /// its line breaks (CRLF and CR become LF, spaces within a line collapse, blank-line runs shrink to one, ends are trimmed);
    /// every other field collapses all whitespace, line breaks included, to single spaces.
    static func normalize(_ raw: String, field: Field) -> String {
        let invisible: Set<UInt32> = [0x200B, 0x2060, 0xFEFF]
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            // Checked BEFORE whitespace: Foundation counts U+200B as whitespace.
            if invisible.contains(scalar.value) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { scalars.append(scalar); continue }
            if scalar.properties.generalCategory == .control { continue }
            scalars.append(scalar)
        }
        let filtered = String(scalars)
        var text: String
        if field == .caption {
            let unified = filtered.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            var lines: [String] = []
            for piece in unified.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = piece.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if line.isEmpty, lines.last?.isEmpty == true { continue }
                lines.append(line)
            }
            text = lines.joined(separator: "\n")
        } else {
            text = filtered.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        }
        text = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(text.prefix(maximumLength(field)))
        while text.utf8.count > maximumBytes(field), !text.isEmpty { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
