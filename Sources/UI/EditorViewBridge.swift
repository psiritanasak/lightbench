import SwiftUI

/// The coarse Editor state the View menu reads. Only values that change rarely (a mode, a tab, a flag): the menu bar lives in the scene,
/// whose body re-runs whenever the bridge publishes, so nothing that changes continuously during an interaction may be added here.
struct EditorViewStatus: Equatable {
    var compareMode: CompareViewMode = .off
    var selectedTab: EditorTab = .adjust
    var filmstripVisible = true
    var canCompare = false
    var canRevert = false
    var canExport = false
    var hasOpenImage = false
    /// A sheet, the History popover or another modal is up in the window (what the scene cannot see itself).
    var blocked = false
}

/// The link between the scene's menu bar (which cannot see `ContentView`'s `@State`) and `ContentView`. The menu writes `request`;
/// `ContentView` performs it through `performViewCommand` (which re-checks the rules) and resets it to nil. `ContentView` writes `status`
/// for the menu's enabled states and checkmarks.
final class EditorViewBridge: ObservableObject {
    @Published var request: ViewCommand?
    @Published var status = EditorViewStatus()
}

/// Publishes the status and performs the requests. Its own modifier: `ContentView` is near the type-checker limit.
struct EditorViewBridgeModifier: ViewModifier {
    @ObservedObject var bridge: EditorViewBridge
    let status: EditorViewStatus
    let perform: (ViewCommand) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: status, initial: true) { _, new in
                if bridge.status != new { bridge.status = new }
            }
            .onAppear { bridge.request = nil } // a request left from a closed window must not block choosing it again
            .onChange(of: bridge.request) { _, request in
                guard let request else { return }
                bridge.request = nil
                perform(request)
            }
    }
}
