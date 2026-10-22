import Foundation

/// The state behind the Edit Info sheet (pure, so it can be tested without a view): what each field shows for the selected
/// photos, and which fields the user actually touched. Only touched fields are written back.
struct InfoSheetDraft: Equatable {
    /// What the selection holds for one field.
    enum Initial: Equatable {
        case same(String)
        case mixed
    }

    private(set) var initial: [InfoText.Field: Initial] = [:]
    private(set) var text: [InfoText.Field: String] = [:]
    private(set) var touched: Set<InfoText.Field> = []

    /// `infos` is one entry per edited photo (a photo with no stored info contributes an empty `PhotoInfo`).
    init(infos: [PhotoInfo]) {
        for field in InfoText.Field.allCases {
            let values = Set(infos.map { Self.value($0, field) })
            if values.count <= 1 {
                let value = values.first ?? ""
                initial[field] = .same(value)
                text[field] = value
            } else {
                initial[field] = .mixed
                text[field] = ""
            }
        }
    }

    static func value(_ info: PhotoInfo, _ field: InfoText.Field) -> String {
        switch field {
        case .title: return info.title
        case .caption: return info.caption
        case .creator: return info.creator
        case .copyright: return info.copyright
        }
    }

    func isMixed(_ field: InfoText.Field) -> Bool { initial[field] == .mixed }

    /// A user edit. Text equal to what the field started with (the shared value, or empty for a mixed field) counts as untouched.
    mutating func edit(_ field: InfoText.Field, to newText: String) {
        text[field] = newText
        let start: String
        if case .same(let value)? = initial[field] { start = value } else { start = "" }
        if newText == start { touched.remove(field) } else { touched.insert(field) }
    }

    /// Clears a field on every photo (the way to empty a "Multiple values" field).
    mutating func clear(_ field: InfoText.Field) {
        text[field] = ""
        touched.insert(field)
    }

    var hasChanges: Bool { !touched.isEmpty }

    /// The values and the fields to write.
    var change: (info: PhotoInfo, fields: InfoFields) {
        var info = PhotoInfo()
        var fields: InfoFields = []
        for field in touched {
            let value = text[field] ?? ""
            switch field {
            case .title: info.title = value; fields.insert(.title)
            case .caption: info.caption = value; fields.insert(.caption)
            case .creator: info.creator = value; fields.insert(.creator)
            case .copyright: info.copyright = value; fields.insert(.copyright)
            }
        }
        return (info, fields)
    }
}
