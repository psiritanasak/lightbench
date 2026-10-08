import SwiftUI

/// The rail's second group (under the tabs): Undo, Redo, Revert, History, Compare, Filmstrip, Enhance — what used to be the top
/// toolbar's right-hand buttons. Same faces as the tab entries (`RailEntryLabel`); availability comes from `EditorRailActionRules`
/// (the caller passes the precomputed `canCompare` / `canEnhance`, which depend on ContentView's armed-tool state).
struct EditorRailActions: View {
    @ObservedObject var document: ImageDocumentModel
    @Binding var compareMode: CompareViewMode
    @Binding var splitOrientation: SplitOrientation
    @Binding var isHistoryPresented: Bool
    @Binding var isFilmstripVisible: Bool
    let canCompare: Bool
    let canEnhance: Bool
    let onEnhance: () -> Void

    var body: some View {
        let hasImage = document.currentImage != nil
        VStack(spacing: 6) {
            entry("Undo", "arrow.uturn.backward", enabled: document.canUndo) { document.undo() }
            entry("Redo", "arrow.uturn.forward", enabled: document.canRedo) { document.redo() }
            entry("Revert", "arrow.counterclockwise",
                  enabled: EditorRailActionRules.canRevert(hasImage: hasImage, isEffectivelyIdentity: document.editState.isEffectivelyIdentity)) {
                document.revertToOriginal()
            }
            entry("History", "clock.arrow.circlepath", on: isHistoryPresented,
                  enabled: EditorRailActionRules.canShowHistory(hasImage: hasImage)) {
                isHistoryPresented.toggle()
            }
            .popover(isPresented: $isHistoryPresented, arrowEdge: .leading) {
                HistoryPopoverView(document: document)
            }
            compareMenu
            entry("Filmstrip", "square.grid.3x1", on: isFilmstripVisible) { isFilmstripVisible.toggle() }
            entry("Enhance", "square.resize.up", enabled: canEnhance, action: onEnhance)
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
            RailEntryLabel(title: "Compare", symbol: "rectangle.split.2x1", isOn: compareMode != .off, isEnabled: canCompare)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Same fixed cell as every other entry: a bare borderless `Menu` pads itself and would push the entries below it out of line.
        .frame(width: EditorToolRailMetrics.width - 8, height: RailEntryLabel.height)
        .disabled(!canCompare)
        .help("Compare")
        .accessibilityLabel("Compare")
        .accessibilityAddTraits(compareMode != .off ? [.isSelected] : [])
    }

    private func entry(_ title: String, _ symbol: String, on: Bool = false, enabled: Bool = true,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RailEntryLabel(title: title, symbol: symbol, isOn: on, isEnabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
