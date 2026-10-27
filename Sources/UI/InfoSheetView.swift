import SwiftUI

/// The four Info fields (Title, Caption, Creator, Copyright), shared by the Library's Edit Info sheet and the Editor's Info popover
/// so they cannot drift. It only DISPLAYS a draft and reports edits; the owner holds the `InfoSheetDraft`. A field shows its value when
/// every edited photo agrees and "Multiple values" otherwise (a popover edits one photo, so it never shows that).
struct InfoFieldsView: View {
    let draft: InfoSheetDraft
    let edit: (InfoText.Field, String) -> Void
    let clear: (InfoText.Field) -> Void

    /// What a copy edit means, in one place for both views. `count` virtual copies are among the edited photos.
    static func copyNote(count: Int) -> String {
        "\(count == 1 ? "A virtual copy shares" : "\(count) virtual copies share") the original's info: changes go to the original."
    }

    /// The reassurance every Info editor shows.
    static let catalogOnlyNote = "Info is stored in the catalog only — your original files are never changed."

    @FocusState private var focused: InfoText.Field?

    // MARK: Fields

    private func binding(_ field: InfoText.Field) -> Binding<String> {
        Binding(get: { draft.text[field] ?? "" }, set: { edit(field, $0) })
    }

    /// Tab in the Caption editor would insert a tab character: move to the next field instead (Shift-Tab: the previous one).
    /// Option / Control-Tab are left alone.
    private func captionTab(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.option), !press.modifiers.contains(.control) else { return .ignored }
        focused = press.modifiers.contains(.shift) ? .title : .creator
        return .handled
    }

    private func row(_ title: String, _ field: InfoText.Field, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                if draft.isMixed(field), !draft.touched.contains(field) {
                    Text("Multiple values").font(.caption).foregroundStyle(Theme.textSecondary)
                } else if draft.isMixed(field) {
                    Text("Will replace the different values").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if draft.isMixed(field) {
                    Button("Clear") { clear(field) }
                        .buttonStyle(FlatButtonStyle(compact: true))
                        .accessibilityLabel("Clear \(title) on every selected photo")
                }
            }
            if multiline {
                TextEditor(text: binding(field))
                    .font(.body)
                    .frame(height: 80)
                    .focused($focused, equals: field)
                    .onKeyPress(keys: [.tab], action: captionTab)
                    .accessibilityLabel(title)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline))
            } else {
                TextField(draft.isMixed(field) ? "Multiple values" : "", text: binding(field))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: field)
                    .accessibilityLabel(title)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Title", .title)
            row("Caption", .caption, multiline: true)
            row("Creator", .creator)
            row("Copyright", .copyright)
        }
    }
}

/// The Library's "Edit Info…" sheet over a snapshot of the selected photo ids: Title, Caption, Creator and Copyright.
/// A field shows its value when every selected photo agrees and "Multiple values" otherwise; only fields the user touched are
/// written. Info lives in the catalog only (never in the original photo files).
struct InfoSheetView: View {
    @ObservedObject var catalog: CatalogModel
    /// The snapshot taken when the sheet opened; `livePhotos` drops photos that have since left the catalog.
    let photoIDs: [Int64]
    /// How many of the edited photos the current filters hide from the grid.
    let hiddenCount: Int
    let onDone: () -> Void

    @State private var draft: InfoSheetDraft

    private let livePhotos: [Photo]

    init(catalog: CatalogModel, photoIDs: [Int64], hiddenCount: Int, onDone: @escaping () -> Void) {
        self.catalog = catalog
        self.photoIDs = photoIDs
        self.hiddenCount = hiddenCount
        self.onDone = onDone
        let wanted = Set(photoIDs)
        let live = catalog.photos.filter { $0.id.map(wanted.contains) ?? false }
        livePhotos = live
        _draft = State(initialValue: InfoSheetDraft(infos: live.map { catalog.info(for: $0) }))
    }

    private var copyCount: Int { livePhotos.filter(\.isVirtualCopy).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Info for \(livePhotos.count) Photo\(livePhotos.count == 1 ? "" : "s")").font(.headline)
            if hiddenCount > 0 {
                Text("\(hiddenCount) of them \(hiddenCount == 1 ? "is" : "are") hidden by the current filters and will be changed too.")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            if copyCount > 0 {
                Text(InfoFieldsView.copyNote(count: copyCount))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Text("\(InfoFieldsView.catalogOnlyNote) Only the fields you edit are changed.")
                .font(.caption).foregroundStyle(Theme.textSecondary)

            InfoFieldsView(draft: draft, edit: { draft.edit($0, to: $1) }, clear: { draft.clear($0) })

            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction).buttonStyle(.flat)
                Button("Save") {
                    let change = draft.change
                    if !change.fields.isEmpty { catalog.setInfo(change.info, fields: change.fields, for: photoIDs) }
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(FlatButtonStyle(prominent: true))
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Presents `InfoSheetView` whenever `catalog.infoSheetPhotoIDs` is set, and performs the Photo menu's request
/// (`catalog.infoSheetRequested`) unless another sheet or dialog is up (`blocked`). Same shape as `KeywordSheetModifier`.
struct InfoSheetModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.infoSheetRequested) { _, requested in
                guard requested else { return }
                catalog.infoSheetRequested = false
                if !blocked && catalog.infoSheetPhotoIDs == nil { catalog.beginEditingInfo() }
            }
            .sheet(isPresented: Binding(
                get: { catalog.infoSheetPhotoIDs != nil },
                set: { if !$0 { catalog.infoSheetPhotoIDs = nil } }
            )) {
                let ids = catalog.infoSheetPhotoIDs ?? []
                let shown = Set(catalog.displayedPhotos.compactMap(\.id))
                InfoSheetView(
                    catalog: catalog, photoIDs: ids, hiddenCount: ids.filter { !shown.contains($0) }.count
                ) { catalog.infoSheetPhotoIDs = nil }
            }
    }
}
