import SwiftUI

/// Progress panel while a catalog backup is written or checked.
struct CatalogBackupWorkingHUD: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working on the catalog backup…").font(.caption)
        }
        .padding(12)
        .solidPanel(cornerRadius: 10)
        .padding(.bottom, 16)
    }
}

/// Confirmation dialog, progress HUD and result alert for Back Up / Restore. Bundled inside `LibraryToolSheetsModifier`
/// (`ContentView.body` is at the type-checker's limit). The File menu only REQUESTS through `catalog.backupRequested`; a request made while
/// another sheet is up is refused with a message (`blocked`).
struct CatalogBackupDialogModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: CatalogBackupModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.backupRequested) { _, kind in
                guard let kind else { return }
                catalog.backupRequested = nil
                if blocked { model.statusMessage = "Close the open sheet first, then try again." } else { model.request(kind, catalog: catalog) }
            }
            .confirmationDialog(
                model.pendingRestore.map(CatalogBackupModel.restoreConfirmationTitle) ?? "Restore catalog",
                isPresented: Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.pendingRestore = nil } }),
                titleVisibility: .visible,
                presenting: model.pendingRestore
            ) { request in
                Button("Restore on Next Launch", role: .destructive) { model.confirmRestore(request) }
                Button("Cancel", role: .cancel) { model.cancelRestore() }
            } message: { request in
                Text(CatalogBackupModel.restoreConfirmationMessage(request))
            }
            .alert(
                "Catalog Backup",
                isPresented: Binding(get: { model.statusMessage != nil }, set: { if !$0 { model.statusMessage = nil } }),
                presenting: model.statusMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .overlay(alignment: .bottom) {
                if model.isWorking { CatalogBackupWorkingHUD() }
            }
    }
}
