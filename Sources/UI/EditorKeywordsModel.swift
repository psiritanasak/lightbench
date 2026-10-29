import Foundation

/// The state behind the Editor's Keywords popover: the open photo's own keywords, edited without leaving the Editor. Same lifecycle as
/// `EditorInfoModel`; keywords belong to each VERSION, so (unlike Info) a virtual copy edits ITS OWN keywords, never its master's.
///
/// Lifecycle (every path is idempotent):
/// - `begin` captures the TARGET photo and seeds the draft from the keywords it has. Beginning again while open commits the first.
/// - `commit` writes the draft's change (adds + removals, one call) to the CAPTURED target, never to whatever photo is open by then, and
///   closes. Text still sitting in the field counts as typed: closing by any route that is not Escape / Cancel saves it.
/// - `discard` closes and writes nothing.
@MainActor
final class EditorKeywordsModel: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var draft = KeywordDraft(initial: [])
    /// The text field's contents (kept here so a commit can save what was typed but not yet submitted).
    @Published var input = ""
    /// The photo this session edits (captured at `begin`); nil when closed.
    private(set) var target: Photo?
    /// The Library's keywords at open time: a typed name that matches one takes its spelling (the database keeps the existing one).
    private var known: [Keyword] = []

    typealias Writer = (_ adding: [String], _ removing: Set<Int64>, _ photo: Photo) -> Void
    private var write: Writer

    /// The default writes nothing: `ContentView` owns this as a `@StateObject` before it has a catalog and wires the real writer with
    /// `configure` on appear.
    init(write: @escaping Writer = { _, _, _ in }) { self.write = write }

    func configure(write: @escaping Writer) { self.write = write }

    /// True when the target is a virtual copy (it has its own keywords; the popover says so).
    var targetIsCopy: Bool { target?.isVirtualCopy ?? false }

    func begin(photo: Photo, current: [Keyword], known: [Keyword] = []) {
        if isOpen { commit() }
        target = photo
        self.known = known
        draft = KeywordDraft(initial: current)
        input = ""
        isOpen = true
    }

    /// The button / ⌘K action: closes (saving) when open; otherwise opens on `photo` if there is one (no catalog row: nothing happens).
    func toggle(photo: Photo?, current: (Photo) -> [Keyword], known: [Keyword] = []) {
        if isOpen { commit(); return }
        guard let photo else { return }
        begin(photo: photo, current: current(photo), known: known)
    }

    func add(text: String) {
        guard isOpen else { return }
        draft.add(text: text, known: known)
    }

    func remove(id: Int64) {
        guard isOpen else { return }
        draft.remove(id: id)
    }

    func undoAdd(name: String) {
        guard isOpen else { return }
        draft.undoAdd(name: name)
    }

    /// Return in the field: the typed text becomes chips and the field empties.
    func submitInput() {
        guard isOpen else { return }
        draft.add(text: input, known: known)
        input = ""
    }

    /// A clicked suggestion: adds that keyword AND removes the half-typed piece it completes (the text after the last comma, semicolon
    /// or newline), so closing does not also save the fragment as a keyword of its own. Text before that separator stays.
    func acceptSuggestion(_ keyword: Keyword) {
        guard isOpen else { return }
        if let cut = input.lastIndex(where: { $0 == "," || $0 == ";" || $0 == "\n" || $0 == "\r" }) {
            var end = input.index(after: cut)
            while end < input.endIndex, input[end] == " " || input[end] == "\t" { end = input.index(after: end) } // the spaces before the fragment stay
            input = String(input[..<end])
        } else {
            input = ""
        }
        draft.add(text: keyword.name, known: known)
    }

    func suggestions(among pool: [Keyword]) -> [Keyword] {
        draft.suggestions(forInput: input, among: pool)
    }

    func commit() {
        guard isOpen, let target else { close(); return }
        draft.add(text: input, known: known)
        let change = draft.change
        let hasChanges = draft.hasChanges
        close()
        if hasChanges { write(change.adding, change.removing, target) }
    }

    func discard() { close() }

    private func close() {
        isOpen = false
        target = nil
        input = ""
        known = []
        draft = KeywordDraft(initial: [])
    }
}

/// When the Photo menu's "Edit Keywords…" (⌘K) is unavailable. One item, two meanings: in the Library it opens the sheet over the selection
/// (`libraryBlocked` carries that item's other-sheet / busy conditions); in the Editor it toggles the popover on the open photo, which needs
/// a loaded photo with a catalog row. Never blocked while ITS popover is open (⌘K is how it closes from the keyboard), but off while the
/// Info popover is open (never two popovers at once).
enum EditorKeywordsMenuRules {
    static func isDisabled(showLibrary: Bool, cullActive: Bool, libraryBlocked: Bool, hasOpenPhoto: Bool, loadInFlight: Bool,
                           hasCatalogRow: Bool, popoverOpen: Bool, infoOpen: Bool) -> Bool {
        if cullActive { return true }
        if showLibrary { return libraryBlocked }
        if popoverOpen { return false }
        if infoOpen { return true }
        return !hasOpenPhoto || !hasCatalogRow || loadInFlight
    }
}
