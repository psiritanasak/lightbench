import SwiftUI

/// Presents Photo Merge's confirmation dialog, progress row (the activity strip) and result (relayed to the window's feedback: a toast or an alert). Bundled inside `LibraryToolSheetsModifier` (not added to
/// `ContentView` directly: its `body` is at the type-checker's limit). The Photo menu, the right-click menu and the selection bar only REQUEST through
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
                switch request.kind {
                case .hdr:
                    Button("Merge — Auto-align") { model.confirm(request, option: .hdr(align: true), catalog: catalog) }
                    Button("Merge — Tripod (no alignment)") { model.confirm(request, option: .hdr(align: false), catalog: catalog) }
                case .panorama:
                    Button("Stitch — Crop to Fill") { model.confirm(request, option: .panorama(crop: true), catalog: catalog) }
                    Button("Stitch — Keep Edges") { model.confirm(request, option: .panorama(crop: false), catalog: catalog) }
                }
                Button("Cancel", role: .cancel) { model.cancel() }
            } message: { request in
                Text(MergeModel.confirmationMessage(request))
            }
            .relayFeedback($model.feedback, to: catalog.post)
            .onChange(of: model.activityItem, initial: true) { _, item in catalog.activity.set(.merge, item) }
            .onDisappear { catalog.activity.set(.merge, nil) }
    }
}
