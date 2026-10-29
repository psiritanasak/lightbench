import SwiftUI

/// The Editor's Keywords popover (opened from the rating bar's Keywords button or ⌘K): the OPEN photo's own keywords as chips, a field to
/// add more (Return makes chips; an empty Return saves), and shortcuts for keywords already in the Library.
/// Escape or Cancel discards; Done, clicking outside, switching photo or leaving the Editor saves (`EditorKeywordsModel`). The popover is
/// its own window, so the Editor's plain-key shortcuts (1-5, P, X ...) cannot fire while typing here.
struct EditorKeywordsPopover: View {
    @ObservedObject var model: EditorKeywordsModel
    /// Every keyword in the Library (the suggestion pool).
    let allKeywords: [Keyword]
    @FocusState private var fieldFocused: Bool

    // MARK: Body

    var body: some View {
        let chips = model.draft.chips
        let suggestions = model.suggestions(among: allKeywords)
        VStack(alignment: .leading, spacing: 12) {
            Text("Keywords").font(.headline).foregroundStyle(Theme.textPrimary)
            if model.targetIsCopy {
                Text("Keywords are this version's own: a virtual copy keeps keywords apart from its original.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Stored in the Library only; your original file is never changed. Changes are saved when you close this; Esc discards.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Add keywords, separated by commas", text: $model.input)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityLabel("New keywords")
                // Return with text makes chips; Return on an empty field is "Done".
                .onSubmit { if KeywordName.parse(model.input).isEmpty { model.commit() } else { model.submitInput() } }

            if chips.isEmpty {
                Text("No keywords yet").font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                FlowRow(spacing: 6) {
                    ForEach(chips) { chip in
                        Button {
                            if let id = chip.keywordID { model.remove(id: id) } else { model.undoAdd(name: chip.name) }
                        } label: {
                            Label(chip.name, systemImage: "xmark.circle.fill")
                                .foregroundStyle(chip.isPending ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .buttonStyle(FlatButtonStyle(isOn: chip.isPending, compact: true))
                        .accessibilityLabel(chip.isPending ? "Remove new keyword \(chip.name)" : "Remove keyword \(chip.name)")
                    }
                }
            }

            if !suggestions.isEmpty {
                Text("Add an existing keyword").font(.subheadline).foregroundStyle(Theme.textPrimary)
                FlowRow(spacing: 6) {
                    ForEach(suggestions) { keyword in
                        Button(keyword.name) { model.acceptSuggestion(keyword) }
                            .buttonStyle(FlatButtonStyle(compact: true))
                            .accessibilityLabel("Add existing keyword \(keyword.name)")
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.discard() }.keyboardShortcut(.cancelAction).buttonStyle(.flat)
                Button("Done") { model.commit() }.buttonStyle(FlatButtonStyle(prominent: true))
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
        .onExitCommand { model.discard() }
        // A system popover is translucent; a solid panel behind the content, like the Info popover.
        .background(Theme.panel)
    }
}

// MARK: - Lifecycle

/// Ties the Keywords popover to the Editor, like `EditorInfoLifecycle`: mirrors `isOpen` to `catalog.editorKeywordsOpen` (the menus
/// observe the catalog), performs the menu's ⌘K request, saves (never discards) what was typed when the open photo changes or the Editor is
/// left, and hands keyboard focus back to the image pane after the popover closes (not when the dismissing click landed on a text field).
struct EditorKeywordsLifecycle: ViewModifier {
    @ObservedObject var model: EditorKeywordsModel
    @ObservedObject var catalog: CatalogModel
    let editKey: String?
    let showLibrary: Bool
    let toggle: () -> Void
    let focusImagePane: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: model.isOpen) { _, open in
                catalog.editorKeywordsOpen = open
                guard !open, !showLibrary else { return }
                DispatchQueue.main.async {
                    guard !showLibrary, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                    focusImagePane()
                }
            }
            // The popover captured its photo, so this saves to the photo it was opened on, not the one now open.
            .onChange(of: editKey) { _, _ in model.commit() }
            .onChange(of: showLibrary) { _, _ in model.commit() }
            .onChange(of: catalog.editorKeywordsToggleRequested) { _, requested in
                guard requested else { return }
                catalog.editorKeywordsToggleRequested = false
                toggle()
            }
    }
}
