import AppKit
import SwiftUI

/// The ONE generic alert for a `Feedback`, fed by one or more bindings through ONE `FeedbackInbox` and ONE `.alert(` (several stacked alert
/// modifiers on one window can leave an alert stuck when two fire together). Every value a model sets is taken at once and its binding
/// cleared. A toast-kind result goes to the `ToastCenter`; an alert-kind result is shown with its optional action and OK, and stays up
/// until the user closes it: a later result can never take an unread alert down.
///
/// Rule for the models behind the bindings: write `feedback` ONCE per completed action. Two writes to the same binding in one run-loop
/// turn are merged by `onChange` and only the last is seen. Alerts still waiting when the window closes are lost.
struct FeedbackAlertModifier: ViewModifier {
    let sources: [Binding<Feedback?>]
    /// Lists of results other models post into (several can arrive in one turn; none is merged away). Each is emptied as it is taken.
    var queues: [Binding<[Feedback]>] = []
    let perform: (FeedbackAction) -> Void

    @EnvironmentObject private var toasts: ToastCenter
    @State private var inbox = FeedbackInbox()
    /// The title of the alert that is closing, kept so it does not go blank while the alert animates away.
    @State private var lastTitle = ""

    func body(content: Content) -> some View {
        content
            .alert(
                inbox.presented?.title ?? lastTitle,
                isPresented: Binding(
                    get: { inbox.presented != nil },
                    set: { shown in
                        guard !shown, let closing = inbox.presented else { return }
                        lastTitle = closing.title
                        inbox.acknowledge(closing)
                        DispatchQueue.main.async { inbox.presentNext() }
                    }
                ),
                presenting: inbox.presented
            ) { shown in
                if let action = shown.action {
                    Button(action.title) { perform(action) }
                }
                Button("OK", role: .cancel) {}
            } message: { shown in
                Text(shown.message)
            }
            // `initial`: a value set while this view was not in the hierarchy is still taken when it appears.
            .onChange(of: sources.map(\.wrappedValue), initial: true) { _, _ in takeAll() }
            // Emptying a queue below changes it once more; that second pass finds every queue empty and does nothing, so there is no loop.
            .onChange(of: queues.map(\.wrappedValue), initial: true) { _, _ in takeQueued() }
    }

    private func takeQueued() {
        var toastsInThisDrain: [Feedback] = []
        for queue in queues {
            let items = queue.wrappedValue
            guard !items.isEmpty else { continue }
            queue.wrappedValue = []
            toastsInThisDrain += inbox.receive(all: items)
        }
        // A toast replaces the previous one, so when several arrive together only the most severe is shown; every alert is kept.
        if let toast = FeedbackInbox.mostSevereToast(toastsInThisDrain) { toasts.show(toast) }
    }

    private func takeAll() {
        for source in sources {
            guard let new = source.wrappedValue else { continue }
            if let toast = inbox.receive(new) { toasts.show(toast) }
            source.wrappedValue = nil
        }
    }
}

/// Moves a model's single-slot `feedback` into a queue (the window's `feedbackAlert` drains it) as soon as it is set, so a dialog modifier
/// that owns a model the window does not observe can still report through the one inbox.
struct FeedbackRelayModifier: ViewModifier {
    @Binding var source: Feedback?
    let post: (Feedback) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: source, initial: true) { _, new in
            guard let new else { return }
            source = nil
            post(new)
        }
    }
}

extension View {
    /// Reports what the models put in their `feedback` bindings and the results posted to their queues: a toast or an alert, by kind.
    /// Needs a `ToastCenter` in the environment. Apply it ONCE per window with every source.
    func feedbackAlert(_ sources: [Binding<Feedback?>], queues: [Binding<[Feedback]>] = []) -> some View {
        modifier(FeedbackAlertModifier(sources: sources, queues: queues) { action in
            switch action {
            case .revealInFinder(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        })
    }

    /// Forwards `source` to `post` (and clears it) whenever it is set.
    func relayFeedback(_ source: Binding<Feedback?>, to post: @escaping (Feedback) -> Void) -> some View {
        modifier(FeedbackRelayModifier(source: source, post: post))
    }
}
