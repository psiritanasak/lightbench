import SwiftUI

/// The three widths of a sheet (`Theme.Metrics.sheet*Width`): small 460 (a short form), medium 580 (options or a list), large 780 (a
/// master-detail or a wide grid).
enum SheetSize: Equatable {
    case small, medium, large

    var width: CGFloat {
        switch self {
        case .small: return Theme.Metrics.sheetSmallWidth
        case .medium: return Theme.Metrics.sheetMediumWidth
        case .large: return Theme.Metrics.sheetLargeWidth
        }
    }
}

/// The status line at the left of a sheet's footer. `.info` is a plain result ("Added 3 photos", counts), `.caution` something to be
/// careful about, `.error` something that failed or was refused. Colour follows the tone, never the message.
struct SheetStatus: Equatable {
    enum Tone: Equatable { case info, caution, error }
    var text: String
    var tone: Tone = .info

    /// A model's free-text `statusMessage` as a footer status: a failure ("Couldn't...", "...failed", "That didn't work", "isn't ready")
    /// is `.error`, a refusal or partial result ("Nothing to...", "Cancelled", "could not be compared", "no face print", "gap changed",
    /// a Rename in progress) is `.caution`, anything else is a plain `.info` result.
    static func classifying(_ text: String?) -> SheetStatus? {
        guard let text else { return nil }
        let lower = text.lowercased()
        let errors = ["couldn't", "failed", "didn't work", "isn't ready"]
        let cautions = ["nothing to", "cancelled", "could not be compared", "no face print", "gap changed", "no photos to", "in progress"]
        if errors.contains(where: lower.contains) { return SheetStatus(text: text, tone: .error) }
        if cautions.contains(where: lower.contains) { return SheetStatus(text: text, tone: .caution) }
        return SheetStatus(text: text, tone: .info)
    }
}

/// What a sheet's footer offers, in the macOS order (the primary action last, at the right).
/// - `.done`: a sheet that applies live and only closes. One flat "Done". With `returnKey` (the default) Return closes it too and Esc is
///   bound by a hidden button; without it (the body already owns a Return default, e.g. a Scan button) Done is only the Esc button.
/// - `.commit`: a sheet that applies on a verb. A flat Cancel (Esc), then the prominent verb (Return, unless `primaryIsDefault` is
///   false: Import Copy's destructive Move mode must never be one stray Return away).
/// A body with its own text field must pass `returnKey: false` to `.done`: Return would otherwise press Done and close the sheet instead of
/// submitting the field.
enum SheetActions: Equatable {
    case done(returnKey: Bool = true)
    case commit(verb: String, enabled: Bool = true, primaryIsDefault: Bool = true, cancelEnabled: Bool = true)
    /// A sheet that stays open after its verb (Auto Stack's Apply) and whose body owns the Return default: a flat Done (Esc, disabled
    /// while `doneEnabled` is false, e.g. mid-apply) then the prominent verb at the right, with no key binding of its own.
    case doneAndApply(verb: String, enabled: Bool = true, doneEnabled: Bool = true)
}

/// One footer button, resolved from `SheetActions` (pure, so the order and the key bindings are testable).
struct SheetButtonSpec: Equatable {
    enum Shortcut: Equatable { case cancelAction, defaultAction, none }
    var title: String
    var prominent: Bool
    var shortcut: Shortcut
    var enabled: Bool
    /// True only for the commit verb (calls `onPrimary`). Done is deliberately NOT primary: it just closes, like Cancel (`onDismiss`).
    var isPrimary: Bool
}

enum SheetFooterRules {
    /// The visible buttons, left to right.
    static func buttons(for actions: SheetActions) -> [SheetButtonSpec] {
        switch actions {
        case .done(let returnKey):
            return [SheetButtonSpec(title: "Done", prominent: false, shortcut: returnKey ? .defaultAction : .cancelAction, enabled: true,
                                    isPrimary: false)]
        case .commit(let verb, let enabled, let primaryIsDefault, let cancelEnabled):
            return [SheetButtonSpec(title: "Cancel", prominent: false, shortcut: .cancelAction, enabled: cancelEnabled, isPrimary: false),
                    SheetButtonSpec(title: verb, prominent: true, shortcut: primaryIsDefault ? .defaultAction : .none, enabled: enabled,
                                    isPrimary: true)]
        case .doneAndApply(let verb, let enabled, let doneEnabled):
            return [SheetButtonSpec(title: "Done", prominent: false, shortcut: .cancelAction, enabled: doneEnabled, isPrimary: false),
                    SheetButtonSpec(title: verb, prominent: true, shortcut: .none, enabled: enabled, isPrimary: true)]
        }
    }

    /// A Done that answers to Return has no Esc button of its own, so the scaffold adds a hidden one.
    static func needsHiddenEscape(for actions: SheetActions) -> Bool {
        if case .done(let returnKey) = actions { return returnKey }
        return false
    }

    static func color(for tone: SheetStatus.Tone) -> Color {
        switch tone {
        case .info: return Theme.textSecondary
        case .caution: return Theme.warning
        case .error: return Theme.error
        }
    }
}

/// The one layout of a sheet: a headline title, the content, then a footer with optional leading content and the status line at the left
/// and the buttons at the right. 20 pt of padding all round, a fixed width from `SheetSize`, and an optional fixed height for sheets
/// whose body scrolls. The caller keeps its own busy state (`.interactiveDismissDisabled`, disabled buttons through `SheetActions`).
struct SheetScaffold<Leading: View, Content: View>: View {
    let title: String
    var size: SheetSize = .medium
    var height: CGFloat?
    var status: SheetStatus?
    let actions: SheetActions
    /// Closes the sheet: Done, or Cancel.
    let onDismiss: () -> Void
    /// The commit verb (ignored for `.done`).
    var onPrimary: () -> Void = {}
    @ViewBuilder var leading: Leading
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if height != nil {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                content
            }
            footer
        }
        .padding(Theme.Metrics.sheetPadding)
        .frame(width: size.width)
        .frame(height: height)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            leading
            if let status {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(SheetFooterRules.color(for: status.tone))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ForEach(Array(SheetFooterRules.buttons(for: actions).enumerated()), id: \.offset) { _, spec in
                button(spec)
            }
        }
        .background {
            if SheetFooterRules.needsHiddenEscape(for: actions) {
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func button(_ spec: SheetButtonSpec) -> some View {
        let base = Button(spec.title, action: spec.isPrimary ? onPrimary : onDismiss)
            .buttonStyle(FlatButtonStyle(prominent: spec.prominent))
            .disabled(!spec.enabled)
            .fixedSize()
        switch spec.shortcut {
        case .cancelAction: base.keyboardShortcut(.cancelAction)
        case .defaultAction: base.keyboardShortcut(.defaultAction)
        case .none: base
        }
    }
}

extension SheetScaffold where Leading == EmptyView {
    init(title: String, size: SheetSize = .medium, height: CGFloat? = nil, status: SheetStatus? = nil, actions: SheetActions,
         onDismiss: @escaping () -> Void, onPrimary: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.init(title: title, size: size, height: height, status: status, actions: actions, onDismiss: onDismiss, onPrimary: onPrimary,
                  leading: { EmptyView() }, content: content)
    }
}
