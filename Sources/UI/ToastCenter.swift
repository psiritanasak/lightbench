import AppKit
import SwiftUI

/// Owns the one visible toast: it shows a `Feedback` that is a toast kind, announces it to VoiceOver, and runs the pure `ToastTimeline` clock
/// through injected hooks (time, timers, announcements, actions), so tests drive every timer fire by hand.
@MainActor
final class ToastCenter: ObservableObject {
    struct Hooks {
        var now: () -> Date
        /// Calls the closure once after the delay. The center never loops on its own: each fire re-arms only if the timeline asks.
        var schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
        var announce: (String) -> Void
        var voiceOverOn: () -> Bool
        var perform: (FeedbackAction) -> Void

        static var live: Hooks {
            Hooks(
                now: { Date() },
                schedule: { delay, fire in
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        fire()
                    }
                },
                announce: { text in AccessibilityNotification.Announcement(text).post() },
                voiceOverOn: { NSWorkspace.shared.isVoiceOverEnabled },
                perform: { action in
                    switch action {
                    case .revealInFinder(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
                    }
                }
            )
        }
    }

    @Published private(set) var timeline = ToastTimeline()

    var current: ToastTimeline.Entry? { timeline.current }

    private let hooks: Hooks

    init(hooks: Hooks = .live) {
        self.hooks = hooks
    }

    // MARK: Showing

    /// Shows a toast. An alert-kind feedback is ignored (it must go through an alert, never a timer); the timeline refuses it too.
    func show(_ feedback: Feedback) {
        guard feedback.presentation == .toast else { return }
        let wake = timeline.show(feedback, now: hooks.now(), voiceOver: hooks.voiceOverOn())
        hooks.announce("\(feedback.title). \(feedback.message)")
        arm(wake)
    }

    // MARK: Pausing

    func setHovering(_ on: Bool) { setPaused(.hover, on) }
    func setSheetPresented(_ on: Bool) { setPaused(.sheet, on) }
    func setAppActive(_ active: Bool) { setPaused(.appInactive, !active) }

    private func setPaused(_ reason: ToastTimeline.PauseReason, _ paused: Bool) {
        arm(timeline.setPaused(reason, paused, now: hooks.now()))
    }

    // MARK: Ending

    func dismiss(id: Int) {
        timeline.dismiss(id: id)
    }

    /// Runs the toast's action, then dismisses it. A stale id does nothing.
    func performAction(id: Int) {
        guard let entry = timeline.current, entry.id == id else { return }
        if let action = entry.feedback.action { hooks.perform(action) }
        timeline.dismiss(id: id)
    }

    // MARK: Timers

    private func arm(_ wake: ToastTimeline.Wake?) {
        guard let wake else { return }
        hooks.schedule(wake.after) { [weak self] in self?.fire(wake) }
    }

    private func fire(_ wake: ToastTimeline.Wake) {
        switch timeline.wake(wake, now: hooks.now()) {
        case .ignored, .expired: break
        case .again(let next): arm(next)
        }
    }
}
