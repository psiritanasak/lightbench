import SwiftUI

/// Confirmation dialog, progress row (the activity strip) and result (relayed to the window's feedback: a toast or an alert) for Back Up / Restore. Bundled inside `LibraryToolSheetsModifier`
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
            .relayFeedback($model.feedback, to: catalog.post)
            .onChange(of: model.activityItem, initial: true) { _, item in catalog.activity.set(.backup, item) }
            .onDisappear { catalog.activity.set(.backup, nil) }
    }
}
