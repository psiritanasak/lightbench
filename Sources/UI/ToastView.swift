import SwiftUI

/// The passing result of an action: an icon, the title, the message, an optional action button and a dismiss button. Sizes and spacing are
/// by-eye conventions. Both buttons are `.focusable(false)` so a toast never takes the key focus Cull relies on.
struct ToastView: View {
    let entry: ToastTimeline.Entry
    var onHover: (Bool) -> Void
    var onAction: () -> Void
    var onDismiss: () -> Void

    private var feedback: Feedback { entry.feedback }

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(feedback.title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(feedback.message)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
            if let action = feedback.action {
                Button(action.title, action: onAction)
                    .buttonStyle(.flat)
                    .focusable(false)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.flat)
            .focusable(false)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 480)
        .solidPanel(cornerRadius: 8)
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }

    @ViewBuilder
    private var icon: some View {
        switch feedback.kind {
        case .done:
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.textSecondary)
        case .nothingToDo:
            Image(systemName: "info.circle").foregroundStyle(Theme.textSecondary)
        case .warning, .incomplete, .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        }
    }
}

/// The bottom-centre host for the toast. Progress HUDs are passed in as `extra` (until the activity strip replaces them).
struct FeedbackOverlay<Extra: View>: View {
    @ObservedObject var toasts: ToastCenter
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 8) {
            if let entry = toasts.current {
                ToastView(
                    entry: entry,
                    onHover: { toasts.setHovering($0) },
                    onAction: { toasts.performAction(id: entry.id) },
                    onDismiss: { toasts.dismiss(id: entry.id) }
                )
                .id(entry.id)
            }
            extra()
        }
        .animation(.easeInOut(duration: 0.2), value: toasts.current?.id)
    }
}
