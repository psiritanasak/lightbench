import AppKit
import SwiftUI

/// `EditorRatingBar` wired to the open document's save status: shows the "Edits not saved" chip while
/// `document.sidecarSaveStatus` is not `.ok` and runs its action. A separate view (not code in `ContentView`) so the document's
/// status changes re-render only the bar, and to keep `ContentView` under the type-checker's ceiling.
struct EditorRatingBarHost: View {
    @ObservedObject var document: ImageDocumentModel
    @ObservedObject var meta: EditorPhotoMeta
    let canCopy: Bool
    let onCopy: () -> Void
    var info: EditorInfoModel?
    var onInfo: () -> Void = {}
    /// The Keywords popover (see `EditorRatingBar.keywords`), forwarded unchanged.
    var keywords: EditorKeywordsModel?
    var onKeywords: () -> Void = {}
    var allKeywords: [Keyword] = []

    @State private var confirmReload = false

    var body: some View {
        EditorRatingBar(
            meta: meta, canCopy: canCopy, onCopy: onCopy, info: info, onInfo: onInfo,
            saveStatus: SidecarSaveStatusPresentation.make(
                for: document.sidecarSaveStatus,
                sidecarFileName: document.currentSidecarURL?.lastPathComponent ?? "its edit file"),
            onSaveAction: perform,
            keywords: keywords, onKeywords: onKeywords, allKeywords: allKeywords)
            .confirmationDialog("Reload edits from the saved file?", isPresented: $confirmReload, titleVisibility: .visible) {
                Button("Reload", role: .destructive) { Task { await document.reloadCurrentPhotoFromSidecar() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Edits made since you opened the photo are discarded.")
            }
    }

    private func perform(_ action: SidecarSaveStatusPresentation.Action) {
        switch action {
        case .reload:
            confirmReload = true
        case .showInFinder:
            if let url = document.currentSidecarURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .grantAccess:
            document.grantAccessAndRetrySidecarSave()
        case .tryAgain:
            document.retrySidecarSave()
        }
    }
}
