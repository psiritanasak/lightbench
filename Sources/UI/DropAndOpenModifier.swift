import SwiftUI

/// URLs handed to the app by Finder / the Dock ("Open With", a drop on the app icon) before or after the window exists. The app delegate
/// only ENQUEUES; `DropAndOpenModifier` drains the queue once the UI is up, so an open that arrives at launch is not lost.
@MainActor
final class OpenRequests: ObservableObject {
    static let shared = OpenRequests()
    @Published private(set) var pending: [URL] = []

    func enqueue(_ urls: [URL]) { pending.append(contentsOf: urls) }

    func drain() -> [URL] {
        let urls = pending
        pending = []
        return urls
    }
}

/// Drag-and-drop onto the window and open-from-Finder: a dropped FOLDER is imported, a dropped PHOTO opens in the Editor (like `Open…`).
/// The decisions live in `DroppedItems` (pure); this applies them, gated like the menus (`DroppedItems.refusal`).
struct DropAndOpenModifier: ViewModifier {
    @ObservedObject var document: ImageDocumentModel
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var renameModel: RenameModel
    @ObservedObject var cull: CullModel
    @ObservedObject var requests: OpenRequests = .shared
    @Binding var showLibrary: Bool
    /// Opens that arrived before the catalog finished opening (a cold launch by Finder / the Dock): kept, then handled once it settles.
    @State private var waitingForCatalog: [URL] = []

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                // A drop with no file URL (an image dragged out of a web page arrives as https:) is not accepted, so the cursor says so.
                guard urls.contains(where: \.isFileURL) else { return false }
                handle(urls)
                return true
            }
            .onChange(of: catalog.openSettled) { _, settled in
                guard settled, !waitingForCatalog.isEmpty else { return }
                let waiting = waitingForCatalog
                waitingForCatalog = []
                handle(waiting)
            }
            .onChange(of: requests.pending) { _, pending in
                if !pending.isEmpty { handle(requests.drain()) }
            }
            .task {
                let waiting = requests.drain()
                if !waiting.isEmpty { handle(waiting) }
            }
    }

    private func refusal() -> String? {
        DroppedItems.refusal(
            renameWorking: renameModel.isWorking, renameInProgress: catalog.isRenameInProgress, culling: cull.isActive,
            loadInFlight: document.isLoadInFlight, toolSheetBusy: catalog.toolSheetIsBusy
        )
    }

    private func handle(_ urls: [URL]) {
        // The catalog opens in the background at launch (after a pre-migration backup, which can take seconds): wait for it rather than
        // refusing, or the cold-launch "Open With" / Dock drop of a folder would be lost.
        guard catalog.openSettled else { waitingForCatalog.append(contentsOf: urls); return }
        if let message = refusal() { catalog.importStatusMessage = message; return }
        Task {
            // Classifying scans folders: keep it off the main actor.
            let plan = await Task.detached { DroppedItems.classify(urls) }.value
            // The state can change while the scan runs (a rename or load may have started): check again before acting.
            if let message = refusal() { catalog.importStatusMessage = message; return }
            apply(plan)
        }
    }

    private func apply(_ plan: DroppedItemsPlan) {
        if let message = DroppedItems.leftOutMessage(for: plan) { catalog.importStatusMessage = message }
        if !plan.folders.isEmpty { catalog.importFolders(plan.folders) }
        if let photo = plan.photoToOpen {
            // Switch to the Editor BEFORE the load, like `Open…`, so a RAW photo's loading indicator is visible.
            showLibrary = false
            Task { await document.load(from: photo) }
        }
    }
}
