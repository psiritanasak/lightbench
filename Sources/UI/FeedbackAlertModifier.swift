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
    }

    private func takeAll() {
        for source in sources {
            guard let new = source.wrappedValue else { continue }
            if let toast = inbox.receive(new) { toasts.show(toast) }
            source.wrappedValue = nil
        }
    }
}

extension View {
    /// Reports what the models put in their `feedback` bindings: a toast or an alert, by its kind. Needs a `ToastCenter` in the environment.
    /// Apply it ONCE per window with every source.
    func feedbackAlert(_ sources: Binding<Feedback?>...) -> some View {
        modifier(FeedbackAlertModifier(sources: sources) { action in
            switch action {
            case .revealInFinder(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        })
    }
}
