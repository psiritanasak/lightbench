import SwiftUI

/// The Library's "Edit Keywords…" sheet over a snapshot of the selected photo ids: type comma-separated
/// keywords to add, remove a keyword from the selection, or delete one from the whole catalog. A keyword on
/// only some of the selected photos is labelled "partial". Keywords live in the catalog only (never in the
/// original photo files), so nothing here touches originals; an export can embed them in its copies.
struct KeywordSheetView: View {
    @ObservedObject var catalog: CatalogModel
    /// The snapshot taken when the sheet opened; `liveIDs` drops photos that have since left the catalog.
    let photoIDs: [Int64]
    /// How many of the edited photos the current filters hide from the grid.
    let hiddenCount: Int
    let onDone: () -> Void

    @State private var input = ""
    @State private var pendingDelete: Keyword?

    private var liveIDs: [Int64] {
        let present = Set(catalog.photos.compactMap(\.id))
        return photoIDs.filter { present.contains($0) }
    }

    /// keywordID → how many of the selected photos carry it.
    private func selectionCounts(for ids: [Int64]) -> [Int64: Int] {
        var counts: [Int64: Int] = [:]
        for id in ids {
            for keywordID in catalog.keywordIDsByPhotoID[id, default: []] { counts[keywordID, default: 0] += 1 }
        }
        return counts
    }

    private func commitInput() {
        guard !catalog.addKeywords(input, to: liveIDs).isEmpty else { return }
        input = ""
    }

    var body: some View {
        let photoIDs = liveIDs
        let counts = selectionCounts(for: photoIDs)
        let allCounts = catalog.keywordPhotoCounts
        let onSelection = catalog.keywords.filter { counts[$0.id ?? -1, default: 0] > 0 }
        let suggestions = catalog.keywords.filter { counts[$0.id ?? -1, default: 0] < photoIDs.count }
        VStack(alignment: .leading, spacing: 12) {
            Text("Keywords for \(photoIDs.count) Photo\(photoIDs.count == 1 ? "" : "s")").font(.headline)
            if hiddenCount > 0 {
                Text("\(hiddenCount) of them \(hiddenCount == 1 ? "is" : "are") hidden by the current filters and will be changed too.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Keywords are stored in the catalog only — your original files are never changed. Exports can embed them (see the export options).")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                TextField("Add keywords, separated by commas", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New keywords")
                    .onSubmit(commitInput)
                Button("Add", action: commitInput)
                    .disabled(KeywordName.parse(input).isEmpty)
                    .accessibilityLabel("Add keywords")
            }

            Text("On the selected photos").font(.subheadline)
            if onSelection.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 6) {
                    ForEach(onSelection) { keyword in
                        let partial = counts[keyword.id ?? -1, default: 0] < photoIDs.count
                        Button {
                            if let id = keyword.id { catalog.removeKeyword(id: id, from: photoIDs) }
                        } label: {
                            Label(partial ? "\(keyword.name) (partial)" : keyword.name, systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Remove keyword \(keyword.name)")
                    }
                }
            }

            if !suggestions.isEmpty {
                Text("Add an existing keyword").font(.subheadline)
                FlowRow(spacing: 6) {
                    ForEach(suggestions) { keyword in
                        Button(keyword.name) {
                            if keyword.id != nil { catalog.addKeywords(keyword.name, to: photoIDs) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Add existing keyword \(keyword.name)")
                    }
                }
            }

            if !catalog.keywords.isEmpty {
                Text("All keywords").font(.subheadline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(catalog.keywords) { keyword in
                            HStack {
                                Text(keyword.name)
                                Text("\(allCounts[keyword.id ?? -1, default: 0])")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(role: .destructive) { pendingDelete = keyword } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete keyword \(keyword.name) everywhere")
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(
            "Delete keyword “\(pendingDelete?.name ?? "")” from every photo?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Everywhere", role: .destructive) {
                if let id = pendingDelete?.id { catalog.deleteKeyword(id: id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the keyword from the whole catalog. Photo files are not changed.")
        }
    }
}

/// Minimal wrapping row layout for keyword chips.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 400, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// Presents `KeywordSheetView` whenever `catalog.keywordSheetPhotoIDs` is set, and performs the Photo menu's
/// request (`catalog.keywordSheetRequested`) unless another sheet or dialog is up (`blocked`) — SwiftUI would
/// drop a second presentation but leave the binding set, wedging the sheet. A separate modifier (not inline in
/// `ContentView.body`) because that body is at this project's type-checker scaling limit.
struct KeywordSheetModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.keywordSheetRequested) { _, requested in
                guard requested else { return }
                catalog.keywordSheetRequested = false
                if !blocked && catalog.keywordSheetPhotoIDs == nil { catalog.beginEditingKeywords() }
            }
            .sheet(isPresented: Binding(
                get: { catalog.keywordSheetPhotoIDs != nil },
                set: { if !$0 { catalog.keywordSheetPhotoIDs = nil } }
            )) {
                let ids = catalog.keywordSheetPhotoIDs ?? []
                let shown = Set(catalog.displayedPhotos.compactMap(\.id))
                KeywordSheetView(
                    catalog: catalog, photoIDs: ids, hiddenCount: ids.filter { !shown.contains($0) }.count
                ) { catalog.keywordSheetPhotoIDs = nil }
            }
    }
}
