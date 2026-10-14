import SwiftUI

/// Progress panel while XMP files are read or written.
struct XMPWorkingHUD: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working on XMP files…").font(.caption)
        }
        .padding(12)
        .solidPanel(cornerRadius: 10)
        .padding(.bottom, 16)
    }
}

/// Confirmation dialog, progress HUD and result alert for the XMP commands. Bundled inside `LibraryToolSheetsModifier` (`ContentView.body`
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
            .alert(
                "XMP Metadata",
                isPresented: Binding(get: { model.statusMessage != nil }, set: { if !$0 { model.statusMessage = nil } }),
                presenting: model.statusMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .overlay(alignment: .bottom) {
                if model.isWorking { XMPWorkingHUD() }
            }
    }
}
