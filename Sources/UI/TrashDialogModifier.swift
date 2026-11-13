import SwiftUI

/// Confirmation (destructive role, no default button), progress row (the activity strip) and result (relayed to the window's feedback: a toast or an alert) for the Trash commands. Bundled inside
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
                Task { await model.request(kind, shown: shown, scope: catalog.currentScopeName, providers: providers, catalog: catalog) }
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
            .relayFeedback($model.feedback, to: catalog.post)
            .onChange(of: model.activityItem, initial: true) { _, item in catalog.activity.set(.trash, item) }
            .onDisappear { catalog.activity.set(.trash, nil) }
    }
}
