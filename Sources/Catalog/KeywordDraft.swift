import Foundation

/// The Editor's Keywords popover as pure data: the keywords one photo (one VERSION) has, plus what the user has typed in (pending adds)
/// and taken off (removed ids), before anything is written. Names follow `KeywordName` (the same parse / identity as the Library sheet).
struct KeywordDraft: Equatable {
    /// One chip: a keyword the photo has (`keywordID` set) or one typed in and not saved yet (`isPending`).
    struct Chip: Equatable, Identifiable {
        var name: String
        var keywordID: Int64?
        var isPending: Bool
        var id: String { KeywordName.key(for: name) }
    }

    private let initial: [Keyword]
    private var pending: [String] = []
    private var removed = Set<Int64>()

    init(initial: [Keyword]) {
        self.initial = initial.filter { $0.id != nil }
    }

    /// What a commit writes: the names to attach (find-or-create) and the keyword ids to detach.
    var change: (adding: [String], removing: Set<Int64>) { (pending, removed) }
    var hasChanges: Bool { !pending.isEmpty || !removed.isEmpty }

    /// The keywords the photo would have now (existing minus removed, case-insensitively sorted), then the pending ones in typing order.
    var chips: [Chip] {
        let kept = initial.filter { !removed.contains($0.id ?? -1) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { Chip(name: $0.name, keywordID: $0.id, isPending: false) }
        return kept + pending.map { Chip(name: $0, keywordID: nil, isPending: true) }
    }

    /// Adds the keywords parsed from `text` (`KeywordName.parse`). A name the photo already has changes nothing; one the user removed
    /// earlier is put back (the removal is cancelled, no add is recorded); one already pending is not repeated. Returns how many names
    /// had an effect.
    @discardableResult
    mutating func add(text: String, known: [Keyword] = []) -> Int {
        var effective = 0
        for name in KeywordName.parse(text) {
            let key = KeywordName.key(for: name)
            if let existing = initial.first(where: { $0.nameKey == key }) {
                if let id = existing.id, removed.remove(id) != nil { effective += 1 }
            } else if !pending.contains(where: { KeywordName.key(for: $0) == key }) {
                // The database keeps an existing keyword's own spelling, so the chip shows that one.
                pending.append(known.first(where: { $0.nameKey == key })?.name ?? name)
                effective += 1
            }
        }
        return effective
    }

    /// Takes an existing keyword off the photo (ignored for an id the photo does not have).
    mutating func remove(id: Int64) {
        guard initial.contains(where: { $0.id == id }) else { return }
        removed.insert(id)
    }

    /// Drops a pending (typed, unsaved) keyword.
    mutating func undoAdd(name: String) {
        let key = KeywordName.key(for: name)
        pending.removeAll { KeywordName.key(for: $0) == key }
    }

    /// Catalog keywords to offer as shortcuts: not on the draft's photo now, matching the piece of `input` being typed (after the last
    /// comma / semicolon / newline) by name prefix, case-insensitively; sorted by name; at most `limit`. Empty input offers everything.
    func suggestions(forInput input: String, among pool: [Keyword], limit: Int = 8) -> [Keyword] {
        let piece = input.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" || $0 == "\r" }).last
            .map { KeywordName.key(for: String($0).trimmingCharacters(in: .whitespaces)) } ?? ""
        let onPhoto = Set(chips.map { KeywordName.key(for: $0.name) })
        return pool
            .filter { !onPhoto.contains($0.nameKey) && (piece.isEmpty || $0.nameKey.hasPrefix(piece)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(max(0, limit)).map { $0 }
    }
}
