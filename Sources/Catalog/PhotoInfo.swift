import Foundation

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
}
