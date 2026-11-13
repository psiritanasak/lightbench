import SwiftUI

/// Confirmation dialog, progress row (the activity strip) and result (relayed to the window's feedback: a toast or an alert) for the XMP commands. Bundled inside `LibraryToolSheetsModifier` (`ContentView.body`
/// is at the type-checker's limit). The menus only REQUEST through `catalog.xmpRequested`; a request made while another sheet or
/// dialog is up is dropped (`blocked`).
struct XMPDialogModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: XMPModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.xmpRequested) { _, kind in
                guard let kind else { return }
                catalog.xmpRequested = nil
                if !blocked { model.request(kind, photos: catalog.selectedPhotosInDisplayedGrid, catalog: catalog) }
            }
            .confirmationDialog(
                model.pending.map(XMPModel.confirmationTitle) ?? "XMP",
                isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }),
                titleVisibility: .visible,
                presenting: model.pending
            ) { request in
                Button(request.kind == .write ? "Write XMP" : "Read XMP") { model.confirm(request, catalog: catalog) }
                Button("Cancel", role: .cancel) { model.cancel() }
            } message: { request in
                Text(XMPModel.confirmationMessage(request))
            }
            .relayFeedback($model.feedback, to: catalog.post)
            .onChange(of: model.activityItem, initial: true) { _, item in catalog.activity.set(.xmp, item) }
            .onDisappear { catalog.activity.set(.xmp, nil) }
    }
}
