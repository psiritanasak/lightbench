import AppKit
import SwiftUI

/// Photo ▸ Recently Deleted…: photos moved to the Trash, with a catalog-only Restore. No button here moves, copies or deletes a file.
struct RecentlyDeletedSheetView: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: RecentlyDeletedModel
    let onDone: () -> Void

    @State private var confirmEmpty = false

    var body: some View {
        SheetScaffold(title: "Recently Deleted", size: .medium, status: footerStatus, actions: .done(), onDismiss: onDone, leading: {
            Button("Empty List…") { confirmEmpty = true }.buttonStyle(.flat).disabled(model.rows.isEmpty && model.unreadable.isEmpty)
        }) {
            Text(RecentlyDeletedModel.explanation).font(.caption).foregroundStyle(Theme.textSecondary)

            if model.rows.isEmpty && model.unreadable.isEmpty {
                Text("Nothing here. Photos you move to the Trash from Lightbench appear in this list.")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.px10) {
                        ForEach(model.rows) { row in rowView(row) }
                        ForEach(model.unreadable) { item in unreadableView(item) }
                    }
                }
                .frame(minHeight: 200, maxHeight: 420)
            }
        }
        .task { await model.load(catalog: catalog) }
        .confirmationDialog("Empty the Recently Deleted list?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty List", role: .destructive) { Task { await model.emptyList(catalog: catalog) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only clears Lightbench's record of these photos, so they can no longer be restored from here. No file is touched: whatever is in the Finder's Trash stays there.")
        }
    }

    /// The model's message as the footer status, with the tone the model chose for it.
    private var footerStatus: SheetStatus? {
        guard let message = model.statusMessage else { return nil }
        return SheetStatus(text: message, tone: model.statusTone)
    }

    private func unreadableView(_ item: UnreadableDeletedPhoto) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text("Unreadable entry (made by a newer version of Lightbench, or damaged). It cannot be restored here.").font(.caption).foregroundStyle(Theme.textSecondary)
            Button("Remove from List") { Task { await model.forget(item.id, catalog: catalog) } }.buttonStyle(.flat)
        }
        .padding(Theme.Space.px10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.px8))
    }

    private func rowView(_ row: RecentlyDeletedModel.Row) -> some View {
        let entry = row.entry
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if entry.isVirtualCopyEntry {
                    Text("virtual copy").font(.caption).foregroundStyle(Theme.textSecondary)
                } else if entry.copyCount > 0 {
                    Text("+ \(entry.copyCount) virtual cop\(entry.copyCount == 1 ? "y" : "ies")").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(entry.deletedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Text(entry.folder).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.head)
            Text(row.status.message).font(.caption).foregroundStyle(row.status.canRestore ? Theme.textPrimary : Theme.textSecondary)
            HStack {
                Button("Restore") { Task { await model.restore(entry.id, catalog: catalog) } }
                    .buttonStyle(.flat).disabled(!row.status.canRestore || model.isWorking)
                if let trashed = entry.trashedPath {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashed)]) }.buttonStyle(.flat)
                }
                Button("Remove from List") { Task { await model.forget(entry.id, catalog: catalog) } }.buttonStyle(.flat)
            }
        }
        .padding(Theme.Space.px10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.px8))
    }
}

/// Presents `RecentlyDeletedSheetView` when the Photo menu requests it, unless another sheet or dialog is up (`blocked`).
struct RecentlyDeletedSheetModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.recentlyDeletedRequested) { _, requested in
                guard requested else { return }
                catalog.recentlyDeletedRequested = false
                if !blocked && !catalog.recentlyDeletedPresented { catalog.recentlyDeletedPresented = true }
            }
            .sheet(isPresented: $catalog.recentlyDeletedPresented) {
                RecentlyDeletedSheetView(catalog: catalog, model: catalog.recentlyDeleted) { catalog.recentlyDeletedPresented = false }
            }
    }
}
