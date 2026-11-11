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
        case .nothingToDo, .notice:
            Image(systemName: "info.circle").foregroundStyle(Theme.textSecondary)
        case .warning, .incomplete, .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        }
    }
}

// MARK: - Activity strip

/// One solid panel listing what is running: a caption, a determinate bar or a small spinner, and a Cancel button when the item can be
/// stopped. Sizes are by-eye conventions (kept close to the HUDs this replaced); nothing here was measured. Cancel is
/// `.focusable(false)` so it never takes the key focus Cull relies on.
struct ActivityStrip: View {
    let items: [ActivityItem]
    var onCancel: (ActivityItem.Kind) -> Void

    static let cancelHint = "Stops after the current photo. Files already exported are kept."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textPrimary)
                    switch item.progress {
                    case .indeterminate:
                        ProgressView().controlSize(.small)
                    case let .steps(done, total):
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                            .frame(width: 220)
                    }
                    if item.canCancel {
                        Button("Cancel") { onCancel(item.kind) }
                            .buttonStyle(.flat)
                            .focusable(false)
                            .help(Self.cancelHint)
                            .accessibilityHint(Self.cancelHint)
                    }
                }
            }
        }
        .padding(12)
        .solidPanel(cornerRadius: 10)
        .accessibilityElement(children: .contain)
    }
}

/// The bottom-centre host: the toast above the activity strip.
struct FeedbackOverlay: View {
    @ObservedObject var toasts: ToastCenter
    let activities: [ActivityItem]
    var onCancel: (ActivityItem.Kind) -> Void

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
            if !activities.isEmpty {
                ActivityStrip(items: activities, onCancel: onCancel)
            }
        }
        .padding(.bottom, 16)
        .animation(.easeInOut(duration: 0.2), value: toasts.current?.id)
    }
}
