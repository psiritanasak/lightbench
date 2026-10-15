import SwiftUI

/// Progress panel while photos are moved to the Trash.
struct TrashWorkingHUD: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Moving photos to the Trash…").font(.caption)
        }
        .padding(12)
        .solidPanel(cornerRadius: 10)
        .padding(.bottom, 16)
    }
}

/// Confirmation (destructive role, no default button), progress HUD and result alert for the Trash commands. Bundled inside
/// `LibraryToolSheetsModifier`. The menus only REQUEST through `catalog.trashRequested`; a request made while another sheet or dialog is up
/// is dropped (`blocked`). The targets are what the Library SHOWS: `displayedPhotos` for Rejected, `selectedPhotosInDisplayedGrid` for Selected.
struct TrashDialogModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: TrashModel
    let providers: RenameProviders
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.trashRequested) { _, kind in
                guard let kind else { return }
                catalog.trashRequested = nil
                guard !blocked else { return }
                let shown = kind == .rejected ? catalog.displayedPhotos : catalog.selectedPhotosInDisplayedGrid
                model.request(kind, shown: shown, scope: catalog.currentScopeName, providers: providers, catalog: catalog)
            }
            .confirmationDialog(
                model.pending.map(TrashModel.confirmationTitle) ?? "Move to Trash",
                isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }),
                titleVisibility: .visible,
                presenting: model.pending
            ) { request in
                Button("Move to Trash", role: .destructive) { model.confirm(request, providers: providers, catalog: catalog) }
                Button("Cancel", role: .cancel) { model.cancel() }
            } message: { request in
                Text(TrashModel.confirmationMessage(request))
            }
            .alert(
                "Move to Trash",
                isPresented: Binding(get: { model.statusMessage != nil }, set: { if !$0 { model.statusMessage = nil } }),
                presenting: model.statusMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .overlay(alignment: .bottom) {
                if model.isWorking { TrashWorkingHUD() }
            }
    }
}
