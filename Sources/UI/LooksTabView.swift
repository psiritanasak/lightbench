import SwiftUI
import UniformTypeIdentifiers

/// The Editor's Looks tab: the "pick a starting point" controls — Looks (LUT profiles), Style and Presets — moved here out of the
/// Adjust tab. They write the same `EditState` fields as before; only their home changed. The expanded flags stay in
/// `AdjustPanelState` (owned by `ContentView`, hoisted because the tab `switch` tears this view down on every switch).
struct LooksTabView: View {
    @ObservedObject var document: ImageDocumentModel
    /// Presets live in the catalog database.
    @ObservedObject var catalog: CatalogModel
    @Binding var panel: AdjustPanelState

    /// "Save Preset" alert state. Local `@State`, NOT lifted into
    /// `AdjustPanelState` — safe because a presented `.alert` is modal on
    /// macOS, so the user structurally cannot switch tabs (the
    /// thing `AdjustPanelState` exists to survive) while it's up. Unlike
    /// the persistent section-expansion bools, there's no round-trip to
    /// preserve here.
    @State private var isPresentingSaveAlert = false
    /// Bumped after a look is imported/removed: `LookLibrary` is not observable, so the Looks list re-reads it
    /// when this changes.
    @State private var looksRevision = 0
    @State private var lookImportMessage: String?
    @State private var newPresetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Looks")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            looksSectionContainer
            styleSectionContainer
            AdjustSectionContainer(icon: "list.star", title: "Presets", isExpanded: $panel.isPresetsSectionExpanded) {
                presetsSection
            }
            Divider()
            resetLookAndStyleButton
        }
        .alert("Save Preset", isPresented: $isPresentingSaveAlert) {
            TextField("Name", text: $newPresetName)
            Button("Save") {
                // `applyingPreset(onto: .identity)` strips OUT this photo's
                // own geometry/redEyePoints before saving, reusing the same
                // field partition `applyPreset` later reads FROM — so a
                // saved preset is genuinely just "a look", never carrying
                // one photo's crop/straighten/flip/red-eye-point positions
                // as dead data alongside it.
                let reusableState = document.editState.applyingPreset(onto: .identity)
                catalog.createPreset(name: newPresetName, editState: reusableState)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        }
    }

    /// Clears the Look and the whole Style in one undoable step (`ImageDocumentModel.resetLookAndStyle`). Presets have nothing
    /// to reset, and the Adjust tab's own "Reset Adjustments" no longer touches either.
    private var resetLookAndStyleButton: some View {
        Button {
            document.resetLookAndStyle()
        } label: {
            Text("Reset Look & Style")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(document.editState.isLookAndStyleAtIdentity)
    }

    // MARK: - Looks

    /// First section in the sidebar: a look is the base rendering the sliders below it act on (the pipeline
    /// applies it before them). One computed property so `body`'s already-long `VStack` gains a single child.
    private var looksSectionContainer: some View {
        Group {
            AdjustSectionContainer(icon: "camera.filters", title: "Looks", isExpanded: $panel.isLooksSectionExpanded) {
                looksSection
            }
            Divider()
        }
    }

    // MARK: - Style

    /// Second section: a style is a light rendering on top of the user's sliders (render-time nudges + tint), so it sits
    /// right under Looks. One computed property so `body`'s already-long `VStack` gains a single child.
    private var styleSectionContainer: some View {
        Group {
            AdjustSectionContainer(icon: "slider.horizontal.below.square.and.square.filled", title: "Style", isExpanded: $panel.isStyleSectionExpanded) {
                StyleSectionView(document: document)
            }
            Divider()
        }
    }

    private func selectLook(_ id: String) {
        document.editState.lookID = id
        // "None" also restores the non-default intensity to its identity (1), so a cleared look never leaves a
        // phantom edit behind (`lookIntensity != 1` with no look renders as identity but counts as edited).
        if id.isEmpty { document.editState.lookIntensity = 1 }
    }

    private func lookRow(id: String, name: String, onDelete: (() -> Void)? = nil) -> some View {
        let isSelected = document.editState.lookID == id
        return HStack {
            Button {
                selectLook(id)
            } label: {
                HStack {
                    Image(systemName: "checkmark").opacity(isSelected ? 1 : 0).frame(width: 14)
                    Text(name)
                }
            }
            .buttonStyle(.plain)
            .fontWeight(isSelected ? .semibold : .regular)
            .accessibilityLabel(id.isEmpty ? "No look" : "Look \(name)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Spacer()
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Remove look \(name)")
            }
        }
    }

    private var looksSection: some View {
        let _ = looksRevision // re-read `LookLibrary` after an import/remove
        let current = document.editState.lookID
        let userLooks = LookLibrary.shared.userLooks
        return Group {
            lookRow(id: "", name: "None")
            ForEach(BuiltInLooks.all, id: \.id) { look in
                lookRow(id: look.id, name: look.name)
            }
            if !userLooks.isEmpty {
                Text("Imported").font(.caption).foregroundStyle(.secondary)
                ForEach(userLooks, id: \.id) { look in
                    lookRow(id: look.id, name: look.name) { removeUserLook(look) }
                }
            }
            if !current.isEmpty, LookLibrary.shared.cube(for: current) == nil {
                // A sidecar can name a look this Mac doesn't have (another machine, a removed file): it renders
                // as no look and must be visible as such, not silently ignored.
                Text("Look not found — this photo uses a look that isn't installed. It is shown without it.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !current.isEmpty {
                EditSliderRow(
                    label: "Intensity", value: lookIntensityBinding,
                    range: 0...1, identity: 1, displayMultiplier: 100
                ) { String(format: "%.0f%%", $0 * 100) }
            }
            Button("Import .cube…") { importLookFile() }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Import Look")
                .alert(
                    "Import Look",
                    isPresented: Binding(get: { lookImportMessage != nil }, set: { if !$0 { lookImportMessage = nil } })
                ) {
                    Button("OK") {}
                } message: {
                    Text(lookImportMessage ?? "")
                }
        }
    }

    /// Guarded at the call site against non-finite values (a NaN stored in `EditState` would make every
    /// sidecar write throw — the Point Color hazard).
    private var lookIntensityBinding: Binding<Double> {
        Binding(
            get: { document.editState.lookIntensity },
            set: { document.editState.lookIntensity = $0.isFinite ? min(max($0, 0), 1) : 1 }
        )
    }

    private func importLookFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a .cube LUT"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let cube = UTType(filenameExtension: "cube") { panel.allowedContentTypes = [cube] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let look = try LookStore.shared.importCube(from: url)
            looksRevision += 1
            lookImportMessage = "Imported \"\(look.name)\"."
            selectLook(look.id)
        } catch {
            lookImportMessage = error.localizedDescription
        }
    }

    private func removeUserLook(_ look: LookLibrary.UserLook) {
        let alert = NSAlert()
        alert.messageText = "Remove \"\(look.name)\"?"
        alert.informativeText = "Photos that use this look will render without it (also in Export) until it is imported again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try LookStore.shared.remove(id: look.id)
            // The open photo's canvas would keep showing the removed look (nothing in `editState` changed), so
            // switch it to None explicitly — one visible, undoable history step.
            if document.editState.lookID == look.id { selectLook("") }
            looksRevision += 1
        } catch {
            lookImportMessage = error.localizedDescription
        }
    }

    private var presetsSection: some View {
        Group {
            Button("Save Preset…") {
                isPresentingSaveAlert = true
            }
            .frame(maxWidth: .infinity)
            if catalog.presets.isEmpty {
                Text("No saved presets yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(catalog.presets) { preset in
                    HStack {
                        Button(preset.name) {
                            document.applyPreset(preset)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            catalog.deletePreset(preset)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Delete preset \(preset.name)")
                    }
                }
            }
        }
    }
}
