import Foundation

/// The Library fields this app exchanges with standard XMP sidecars (the tag conventions Lightroom / Bridge use):
/// `xmp:Rating` (0...5, -1 = rejected), `xmp:Label` and the flat `dc:subject` keyword bag.
/// A nil member means "absent": on read, the file said nothing; on write, leave that tag alone — EXCEPT that rating
/// and reject share one tag, so writing a `rating` with `isRejected == nil` replaces an existing -1.
/// Interop caveat: Lightroom and Bridge keep XMP INSIDE JPEG/TIFF/DNG and read a `<base>.xmp` sidecar only for proprietary
/// RAW, so a sidecar beside a JPEG is for darktable/digiKam-style tools. Keywords are half-synced: `dc:subject` is replaced
/// but a stale `lr:hierarchicalSubject` is kept (Lightroom prefers it).
/// Pick has no standard XMP field, so it is never exchanged.
///
/// Info panel text (`title` = `dc:title`, `caption` = `dc:description`, `copyright` = `dc:rights`, all language alternatives whose
/// `x-default` entry we own, and `creator` = `dc:creator`, an ordered array): nil means absent (on read) / leave the tag alone (on write),
/// and an EMPTY string on write ALSO leaves the tag alone, so an empty Library value never erases text another app put in the file.
struct XMPLibraryFields: Equatable {
    /// 0...5.
    var rating: Int?
    /// `true` for Rating -1; `false` when the file carries a normal rating (so a catalog Reject can be undone).
    var isRejected: Bool?
    /// `.none` means "explicitly no label"; nil means the file had no (recognised) label.
    var label: ColorLabel?
    var keywords: [String]?
    var title: String?
    var caption: String?
    var creator: String?
    var copyright: String?

    var isEmpty: Bool {
        rating == nil && isRejected == nil && label == nil && keywords == nil
            && title == nil && caption == nil && creator == nil && copyright == nil
    }

    /// The Info panel values as non-nil strings. Empty strings (= nothing to write) are the Library's own "no value".
    init(rating: Int? = nil, isRejected: Bool? = nil, label: ColorLabel? = nil, keywords: [String]? = nil, info: PhotoInfo) {
        self.init(rating: rating, isRejected: isRejected, label: label, keywords: keywords,
                  title: info.title, caption: info.caption, creator: info.creator, copyright: info.copyright)
    }

    init(rating: Int? = nil, isRejected: Bool? = nil, label: ColorLabel? = nil, keywords: [String]? = nil,
         title: String? = nil, caption: String? = nil, creator: String? = nil, copyright: String? = nil) {
        self.rating = rating
        self.isRejected = isRejected
        self.label = label
        self.keywords = keywords
        self.title = title
        self.caption = caption
        self.creator = creator
        self.copyright = copyright
    }

    /// The Info values the file carried (absent ones are empty strings); nil when it carried none.
    var info: PhotoInfo? {
        guard title != nil || caption != nil || creator != nil || copyright != nil else { return nil }
        return PhotoInfo(title: title ?? "", caption: caption ?? "", creator: creator ?? "", copyright: copyright ?? "")
    }

    // MARK: Label names

    /// The names we WRITE (Lightroom's English label names).
    static func labelName(_ label: ColorLabel) -> String? {
        switch label {
        case .none: return nil
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    /// Accepts Lightroom's names and Bridge's default label text; case-insensitive. Unknown text is nil (absent).
    static func label(fromName raw: String) -> ColorLabel? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return ColorLabel.none
        case "red", "select": return .red
        case "yellow", "second": return .yellow
        case "green", "approved": return .green
        case "blue", "review": return .blue
        case "purple", "to do": return .purple
        default: return nil
        }
    }

    // MARK: Rating

    /// The `xmp:Rating` text to write for a catalog photo: -1 for a rejected one, else the star count.
    static func ratingText(rating: Int, isRejected: Bool) -> String {
        isRejected ? "-1" : String(min(max(rating, 0), 5))
    }

    /// Parses `xmp:Rating` text. Out-of-range or non-numeric text is ignored (nil, nil); values above 5 are not trusted.
    static func parseRating(_ raw: String) -> (rating: Int, isRejected: Bool)? {
        // xmp:Rating is typed Real, so "4.0" is legal; accept only whole numbers.
        guard let real = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), real.rounded() == real, abs(real) < 100,
              case let value = Int(real) else { return nil }
        if value == -1 { return (0, true) }
        guard (0...5).contains(value) else { return nil }
        return (value, false)
    }
}
