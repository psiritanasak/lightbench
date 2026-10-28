import SwiftUI

/// The Editor's Info popover (opened from the rating bar's Info button or ⌘I): the OPEN photo's Title / Caption / Creator / Copyright.
/// Escape or Cancel discards; Done, clicking outside, switching photo or leaving the Editor saves what was touched
/// (`EditorInfoModel`). The popover is its own window, so it sits outside the image pane's focusable subtree: the Editor's plain-key
/// shortcuts (1-5, P, X ...) cannot fire while typing here.
struct EditorInfoPopover: View {
    @ObservedObject var model: EditorInfoModel

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Info").font(.headline).foregroundStyle(Theme.textPrimary)
            if model.targetIsCopy {
                Text(InfoFieldsView.copyNote(count: 1)).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(InfoFieldsView.catalogOnlyNote) Changes are saved when you close this; Esc discards.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            InfoFieldsView(draft: model.draft, edit: { model.edit($0, to: $1) }, clear: { _ in })

            HStack {
                Spacer()
                Button("Cancel") { model.discard() }.keyboardShortcut(.cancelAction).buttonStyle(.flat)
                Button("Done") { model.commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(FlatButtonStyle(prominent: true))
            }
        }
        .padding(16)
        .frame(width: 360)
        .onExitCommand { model.discard() }
        // A system popover is translucent; a solid panel behind the content, like the search-help popover and the app's other overlays.
        .background(Theme.panel)
    }
}

// MARK: - Lifecycle

/// Ties the Info popover to the Editor: mirrors `isOpen` (`catalog.editorInfoOpen`) and whether the open photo has a catalog row
/// (`catalog.editorPhotoInCatalog`) to the menus, performs the menu's ⌘I request, saves
/// (never discards) what was typed when the open photo changes or the Editor is left, and hands keyboard focus back to the image pane
/// after the popover closes, exactly like the History popover (not when the dismissing click landed on a text field, an `NSTextView`
/// first responder, checked one run-loop turn later).
struct EditorInfoLifecycle: ViewModifier {
    @ObservedObject var model: EditorInfoModel
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var meta: EditorPhotoMeta
    let editKey: String?
    let showLibrary: Bool
    let toggle: () -> Void
    let focusImagePane: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: meta.photo != nil, initial: true) { _, hasRow in catalog.editorPhotoInCatalog = hasRow }
            .onChange(of: model.isOpen) { _, open in
                catalog.editorInfoOpen = open
                guard !open, !showLibrary else { return }
                DispatchQueue.main.async {
                    guard !showLibrary, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                    focusImagePane()
                }
            }
            // The popover captured its photo, so this saves to the photo it was opened on, not the one now open.
            .onChange(of: editKey) { _, _ in model.commit() }
            .onChange(of: showLibrary) { _, _ in model.commit() }
            .onChange(of: catalog.editorInfoToggleRequested) { _, requested in
                guard requested else { return }
                catalog.editorInfoToggleRequested = false
                toggle()
            }
    }
}
