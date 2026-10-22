import Foundation

/// Decides what applying fields read from an XMP sidecar changes on one catalog photo. Pure.
/// - `.replace` (the manual "Read Metadata from XMP…"): the file wins for every field it carries.
/// - `.fillDefaults` (the silent pass after import): only fields still at their defaults are filled; a value the user
///   already set is never overwritten.
/// Keywords are only ever ADDED (never removed) in both modes. Pick has no XMP field and is only changed by a Reject
/// in the file (or by un-rejecting under `.replace`); an existing Pick is never touched by a non-reject rating.
/// Info text (title, caption, creator, copyright): a NON-EMPTY file value wins under `.replace`; under `.fillDefaults` it only fills a
/// field the catalog has empty. A value the file lacks (or holds blank) never clears the catalog's.
enum XMPImportPolicy {
    enum Mode { case replace, fillDefaults }

    /// The Info fields to change; nil = leave as is.
    struct InfoUpdate: Equatable {
        var title: String?
        var caption: String?
        var creator: String?
        var copyright: String?
        var isEmpty: Bool { title == nil && caption == nil && creator == nil && copyright == nil }

        /// `info` with the changed fields replaced.
        func applying(to info: PhotoInfo) -> PhotoInfo {
            PhotoInfo(title: title ?? info.title, caption: caption ?? info.caption,
                      creator: creator ?? info.creator, copyright: copyright ?? info.copyright)
        }
    }

    struct Change: Equatable {
        var rating: Int?
        var flag: FlagStatus?
        var label: ColorLabel?
        var keywordsToAdd: [String] = []
        var info = InfoUpdate()
        var isEmpty: Bool { rating == nil && flag == nil && label == nil && keywordsToAdd.isEmpty && info.isEmpty }
    }

    /// `currentKeywordKeys` are `KeywordName.key(for:)` values of the photo's current keywords. `currentInfo` is the photo's Info
    /// (its master's, for a virtual copy); the default means "none", which makes every file value look new.
    static func change(current: Photo, currentKeywordKeys: Set<String>, fields: XMPLibraryFields, mode: Mode,
                       currentInfo: PhotoInfo = PhotoInfo()) -> Change {
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
        out.info = infoUpdate(current: currentInfo, fields: fields, mode: mode)
        return out
    }

    /// File text is normalised with the Library's own rules (`InfoText`) BEFORE it is compared or returned: text that normalises to
    /// nothing (only invisible characters) never counts, a difference that normalisation removes (NFD vs NFC, double spaces, over-cap
    /// tails) is no change, and what is returned is exactly what will be stored.
    static func infoUpdate(current: PhotoInfo, fields: XMPLibraryFields, mode: Mode) -> InfoUpdate {
        func pick(_ file: String?, _ now: String, _ field: InfoText.Field) -> String? {
            guard let file else { return nil }
            let value = InfoText.normalize(file, field: field)
            guard !value.isEmpty, value != now else { return nil }
            switch mode {
            case .replace: return value
            case .fillDefaults: return now.isEmpty ? value : nil
            }
        }
        return InfoUpdate(title: pick(fields.title, current.title, .title), caption: pick(fields.caption, current.caption, .caption),
                          creator: pick(fields.creator, current.creator, .creator), copyright: pick(fields.copyright, current.copyright, .copyright))
    }
}
