import SwiftUI

/// The rail's second group (under the tabs): Undo, Redo, Revert, History, Compare, Filmstrip, Enhance — what used to be the top
/// toolbar's right-hand buttons. Icon-only (the name is the tooltip and the VoiceOver label), drawn by the same `RailEntryLabel`
/// as the tabs. Availability comes from `EditorRailActionRules` (the caller passes the precomputed `canCompare` / `canEnhance`,
/// which depend on ContentView's armed-tool state).
struct EditorRailActions: View {
    @ObservedObject var document: ImageDocumentModel
    @Binding var compareMode: CompareViewMode
    @Binding var splitOrientation: SplitOrientation
    @Binding var isHistoryPresented: Bool
    @Binding var isFilmstripVisible: Bool
    let canCompare: Bool
    let canEnhance: Bool
    let onEnhance: () -> Void

    /// The SF Symbol of each entry, in rail order. A symbol name that does not exist on the running macOS draws NOTHING (an icon-only
    /// entry would be blank), so `EditorRailActionsSymbolTests` checks every one of these against the system.
    enum Symbol {
        static let undo = "arrow.uturn.backward"
        static let redo = "arrow.uturn.forward"
        static let revert = "arrow.counterclockwise"
        static let history = "clock.arrow.circlepath"
        static let compare = "rectangle.split.2x1"
        static let filmstrip = "film"
        static let enhance = "square.resize.up"
        static let all = [undo, redo, revert, history, compare, filmstrip, enhance]
    }

    var body: some View {
        let hasImage = document.currentImage != nil
        VStack(spacing: 6) {
            entry("Undo", Symbol.undo, enabled: document.canUndo) { document.undo() }
            entry("Redo", Symbol.redo, enabled: document.canRedo) { document.redo() }
            entry("Revert", Symbol.revert,
                  enabled: EditorRailActionRules.canRevert(hasImage: hasImage, isEffectivelyIdentity: document.editState.isEffectivelyIdentity)) {
                document.revertToOriginal()
            }
            entry("History", Symbol.history, on: isHistoryPresented,
                  enabled: EditorRailActionRules.canShowHistory(hasImage: hasImage)) {
                isHistoryPresented.toggle()
            }
            .popover(isPresented: $isHistoryPresented, arrowEdge: .leading) {
                HistoryPopoverView(document: document)
            }
            compareMenu
            entry("Filmstrip", Symbol.filmstrip, on: isFilmstripVisible) { isFilmstripVisible.toggle() }
            entry("Enhance", Symbol.enhance, enabled: canEnhance, action: onEnhance)
        }
    }

    private var compareMenu: some View {
        Menu {
            Picker("Compare", selection: $compareMode) {
                Text("Off").tag(CompareViewMode.off)
                Text("Side by Side").tag(CompareViewMode.sideBySide)
                Text("Split (Before/After)").tag(CompareViewMode.split)
            }
            if compareMode == .split {
                Divider()
                Picker("Orientation", selection: $splitOrientation) {
                    Text("Vertical").tag(SplitOrientation.vertical)
                    Text("Horizontal").tag(SplitOrientation.horizontal)
                }
            }
        } label: {
            RailEntryLabel(title: "Compare", symbol: Symbol.compare, isOn: compareMode != .off, isEnabled: canCompare, showsTitle: false)
        }
        // `.button` + `.plain` so the label is drawn like the other entries' plain buttons; the tint keeps the root accent from colouring
        // the idle state (it was blue all the time) — grey like its neighbours, a white icon on a grey chip only while Compare is on.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(RailEntryLabel.color(isOn: compareMode != .off, isEnabled: canCompare))
        .menuIndicator(.hidden)
        // Same fixed cell as every other entry: a bare borderless `Menu` pads itself and would push the entries below it out of line.
        .frame(width: EditorToolRailMetrics.width - 8, height: RailEntryLabel.iconOnlyHeight)
        .disabled(!canCompare)
        .help("Compare")
        .accessibilityLabel("Compare")
        .accessibilityAddTraits(compareMode != .off ? [.isSelected] : [])
    }

    private func entry(_ title: String, _ symbol: String, on: Bool = false, enabled: Bool = true,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RailEntryLabel(title: title, symbol: symbol, isOn: on, isEnabled: enabled, showsTitle: false)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
