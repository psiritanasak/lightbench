import AppKit

/// Receives files and folders from Finder / the Dock ("Open With", a drop on the app icon). It only queues them: the SwiftUI side
/// (`DropAndOpenModifier`) decides what to do once the window exists.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in OpenRequests.shared.enqueue(urls) }
    }
}
