import Foundation

/// The state behind the Editor's Info popover: the open photo's Title / Caption / Creator / Copyright, edited without leaving the
/// Editor. Same storage and rules as the Library's Edit Info sheet (catalog only; a virtual copy edits its master's info; only
/// TOUCHED fields are written), reusing `InfoSheetDraft` unchanged.
///
/// Lifecycle (every path is idempotent):
/// - `begin` captures the TARGET photo and seeds the draft from the info it shows. Beginning again while open commits the first.
/// - `commit` writes only the touched fields, to the CAPTURED target (never to whatever photo is open by then), and closes.
///   Closing by any route that is not Escape / Cancel commits: typed text is never lost silently.
/// - `discard` closes and writes nothing.
@MainActor
final class EditorInfoModel: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var draft = InfoSheetDraft(infos: [])
    /// The photo this session edits (captured at `begin`); nil when closed.
    private(set) var target: Photo?

    typealias Writer = (PhotoInfo, InfoFields, [Photo]) -> Void
    private var write: Writer

    /// The default writes nothing: `ContentView` owns this as a `@StateObject` before it has a catalog and wires the real writer
    /// with `configure` on appear.
    init(write: @escaping Writer = { _, _, _ in }) { self.write = write }

    func configure(write: @escaping Writer) { self.write = write }

    /// True when the target is a virtual copy (its info is its master's).
    var targetIsCopy: Bool { target?.isVirtualCopy ?? false }

    func begin(photo: Photo, currentInfo: PhotoInfo) {
        if isOpen { commit() }
        target = photo
        draft = InfoSheetDraft(infos: [currentInfo])
        isOpen = true
    }

    /// The button / ⌘I action: closes (saving) when open; otherwise opens on `photo` if there is one (no catalog row: nothing happens).
    func toggle(photo: Photo?, currentInfo: (Photo) -> PhotoInfo) {
        if isOpen { commit(); return }
        guard let photo else { return }
        begin(photo: photo, currentInfo: currentInfo(photo))
    }

    func edit(_ field: InfoText.Field, to text: String) {
        guard isOpen else { return }
        draft.edit(field, to: text)
    }

    func commit() {
        guard isOpen, let target else { close(); return }
        let change = draft.change
        close()
        if !change.fields.isEmpty { write(change.info, change.fields, [target]) }
    }

    func discard() { close() }

    private func close() {
        isOpen = false
        target = nil
        draft = InfoSheetDraft(infos: [])
    }
}

/// When the Photo menu's "Edit Info…" (⌘I) is unavailable. One item, two meanings: in the Library it opens the sheet over the selection
/// (`libraryBlocked` carries that item's long list of other-sheet / busy conditions, unchanged); in the Editor it toggles the popover on the
/// open photo, which needs a loaded photo with a catalog row (Info is catalog data) and is never blocked while the popover is open (⌘I is how it closes from the keyboard).
enum EditorInfoMenuRules {
    static func isDisabled(showLibrary: Bool, cullActive: Bool, libraryBlocked: Bool, hasOpenPhoto: Bool, loadInFlight: Bool,
                           hasCatalogRow: Bool, popoverOpen: Bool) -> Bool {
        if cullActive { return true }
        if showLibrary { return libraryBlocked }
        if popoverOpen { return false }
        return !hasOpenPhoto || !hasCatalogRow || loadInFlight
    }
}
