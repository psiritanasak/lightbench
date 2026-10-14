import Foundation

/// Decides what applying fields read from an XMP sidecar changes on one catalog photo. Pure.
/// - `.replace` (the manual "Read Metadata from XMP…"): the file wins for every field it carries.
/// - `.fillDefaults` (the silent pass after import): only fields still at their defaults are filled; a value the user
///   already set is never overwritten.
/// Keywords are only ever ADDED (never removed) in both modes. Pick has no XMP field and is only changed by a Reject
/// in the file (or by un-rejecting under `.replace`); an existing Pick is never touched by a non-reject rating.
enum XMPImportPolicy {
    enum Mode { case replace, fillDefaults }

    struct Change: Equatable {
        var rating: Int?
        var flag: FlagStatus?
        var label: ColorLabel?
        var keywordsToAdd: [String] = []
        var isEmpty: Bool { rating == nil && flag == nil && label == nil && keywordsToAdd.isEmpty }
    }

    /// `currentKeywordKeys` are `KeywordName.key(for:)` values of the photo's current keywords.
    static func change(current: Photo, currentKeywordKeys: Set<String>, fields: XMPLibraryFields, mode: Mode) -> Change {
        var out = Change()

        // Rating -1 is a Reject marker, not a star count: it carries no stars, so it never changes the photo's rating.
        if let rating = fields.rating, fields.isRejected != true, rating != current.rating {
            switch mode {
            case .replace: out.rating = rating
            case .fillDefaults: if current.rating == 0, rating > 0 { out.rating = rating }
            }
        }

        switch (fields.isRejected, mode) {
        case (true?, _):
            if current.flagStatus != .rejected, mode == .replace || current.flagStatus == .none { out.flag = .rejected }
        case (false?, .replace):
            if current.flagStatus == .rejected { out.flag = FlagStatus.none }
        default: break
        }

        if let label = fields.label, label != current.colorLabel {
            switch mode {
            case .replace: out.label = label
            case .fillDefaults: if current.colorLabel == .none { out.label = label }
            }
        }

        if let keywords = fields.keywords {
            var seen = currentKeywordKeys
            for raw in keywords {
                guard let name = KeywordName.normalize(raw), seen.insert(KeywordName.key(for: name)).inserted else { continue }
                out.keywordsToAdd.append(name)
            }
        }
        return out
    }
}
