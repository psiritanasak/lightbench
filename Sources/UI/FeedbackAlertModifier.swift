import AppKit
import SwiftUI

/// The ONE generic alert for a `Feedback`. The binding is an inbox: every value a model sets is taken at once and cleared. A toast-kind
/// result goes to the `ToastCenter`; an alert-kind result is shown with its optional action and OK, and stays up until the user closes it
/// (`FeedbackInbox`): a later result can never take an unread alert down.
struct FeedbackAlertModifier: ViewModifier {
    @Binding var feedback: Feedback?
    let perform: (FeedbackAction) -> Void

    @EnvironmentObject private var toasts: ToastCenter
    @State private var inbox = FeedbackInbox()
    /// The last alert shown, kept so the title does not go blank while the alert animates away.
    @State private var lastTitle = ""

    func body(content: Content) -> some View {
        content
            .alert(
                inbox.presented?.title ?? lastTitle,
                isPresented: Binding(
                    get: { inbox.presented != nil },
                    set: { shown in
                        guard !shown else { return }
                        inbox.acknowledge()
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
            .onChange(of: feedback, initial: true) { _, new in
                guard let new else { return }
                if let toast = inbox.receive(new) {
                    toasts.show(toast)
                } else if let title = inbox.presented?.title {
                    lastTitle = title
                }
                feedback = nil
            }
    }
}

extension View {
    /// Reports what a model puts in `feedback`: a toast or an alert, by its kind. Needs a `ToastCenter` in the environment.
    func feedbackAlert(_ feedback: Binding<Feedback?>) -> some View {
        modifier(FeedbackAlertModifier(feedback: feedback) { action in
            switch action {
            case .revealInFinder(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        })
    }
}
