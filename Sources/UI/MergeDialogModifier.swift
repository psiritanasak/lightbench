import SwiftUI

/// Progress panel shown while a merge renders (one atomic call, no incremental progress — like `EnhancingHUD`).
struct MergingHUD: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Merging photos…")
                .font(.caption)
        }
        .padding(12)
        .solidPanel(cornerRadius: 10)
        .padding(.bottom, 16)
    }
}

/// Presents Photo Merge's confirmation dialog, progress HUD and result alert. Bundled inside `LibraryToolSheetsModifier` (not added to
/// `ContentView` directly: its `body` is at the type-checker's limit). The Photo menu / selection menu only REQUEST through
/// `catalog.mergeRequested`; a request made while another sheet or dialog is up is dropped (`blocked`).
struct MergeDialogModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: MergeModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.mergeRequested) { _, kind in
                guard let kind else { return }
                catalog.mergeRequested = nil
                if !blocked { model.request(kind, photos: catalog.selectedPhotosInDisplayedGrid, catalog: catalog) }
            }
            .confirmationDialog(
                model.pending.map(MergeModel.confirmationTitle) ?? "Merge photos",
                isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }),
                titleVisibility: .visible,
                presenting: model.pending
            ) { request in
                Button("Merge — Auto-align") { model.confirm(request, align: true, catalog: catalog) }
                Button("Merge — Tripod (no alignment)") { model.confirm(request, align: false, catalog: catalog) }
                Button("Cancel", role: .cancel) { model.cancel() }
            } message: { request in
                Text(MergeModel.confirmationMessage(request))
            }
            .alert(
                "Photo Merge",
                isPresented: Binding(get: { model.statusMessage != nil }, set: { if !$0 { model.statusMessage = nil } }),
                presenting: model.statusMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .overlay(alignment: .bottom) {
                if model.isMerging { MergingHUD() }
            }
    }
}
