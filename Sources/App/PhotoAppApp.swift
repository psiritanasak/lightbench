import SwiftUI

@main
struct PhotoAppApp: App {
    /// Owns `ImageDocumentModel` here, not in `ContentView`, so the Edit
    /// menu below (a `Scene`-level construct) and the toolbar's own
    /// Undo/Redo buttons in `ContentView` can both act on the SAME
    /// document instance.
    @StateObject private var document = ImageDocumentModel()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document)
        }
        .commands {
            // Replaces macOS's default (inert) Edit > Undo/Redo items —
            // the canonical, keyboard-shortcut-owning home for these
            // actions. Wired to the SAME `document.undo()`/`.redo()` the
            // toolbar buttons already call; `canUndo`/`canRedo` being
            // `@Published` on `document` means these reactively
            // enable/disable in sync with the toolbar.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { document.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!document.canUndo)
                Button("Redo") { document.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!document.canRedo)
            }
        }
    }
}
