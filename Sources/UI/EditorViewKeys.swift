import SwiftUI
import AppKit

/// "Before" badge at the top-left of the Editor's image pane while the unedited photo is shown (`\`). Same solid panel as
/// `ZoomPercentageHUD` (bottom-right); purely informational, never takes a click.
struct BeforeChip: View {
    var body: some View {
        Text("Before")
            .font(.caption)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .solidPanel(cornerRadius: Theme.Radius.m)
            .padding(Theme.Space.m)
            .allowsHitTesting(false)
    }
}

/// Puts the chip over the image pane while `compareMode == .before`. Its own modifier: `ContentView` is near the type-checker limit.
struct BeforeChipOverlay: ViewModifier {
    let compareMode: CompareViewMode

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if compareMode == .before { BeforeChip() }
        }
    }
}

/// The Editor's Before / app-key lifecycle rules, kept out of `ContentView.body`:
/// - an accessibility announcement each time Before turns on or off;
/// - arming any point tool ends Compare / Before (Targeted arming does not pass through `onEnterPointPickingMode`);
/// - on every Library -> Editor change the image pane takes keyboard focus, so the bare app keys work at once, unless a text
///   field has it (checked one run-loop turn later, like the popover hand-back: a slider type-in must keep its focus).
struct EditorBeforeLifecycle: ViewModifier {
    @Binding var compareMode: CompareViewMode
    let armedAny: Bool
    let showLibrary: Bool
    let focusImagePane: () -> Void

    static func announcement(from old: CompareViewMode, to new: CompareViewMode) -> String? {
        if new == .before { return "Showing the original" }
        if old == .before { return "Showing your edits" }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: compareMode) { old, new in
                guard let text = Self.announcement(from: old, to: new) else { return }
                NSAccessibility.post(
                    element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
            .onChange(of: armedAny) { _, armed in
                if armed, compareMode != .off { compareMode = .off }
            }
            .onChange(of: showLibrary) { _, isShowingLibrary in
                // Leaving for the Library ends Before: coming back to the same photo must show the edits.
                if isShowingLibrary, compareMode == .before { compareMode = .off }
                guard !isShowingLibrary else { return }
                DispatchQueue.main.async {
                    guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                    focusImagePane()
                }
            }
    }
}
