import Foundation

// MARK: - Feedback kinds

/// How a finished action went. The kind decides whether the result is a passing toast or an alert the user must dismiss:
/// anything that was NOT fully written is an alert, so nothing a user needs to act on can fade away on a timer.
enum FeedbackKind: String, Equatable, Sendable {
    /// Everything asked for was written (items already in the requested state are fine).
    case done
    /// Nothing needed writing and nothing asked for is left undone.
    case nothingToDo
    /// Everything asked for was written, with a caveat that needs no decision (smallest quality used, a fallback, a user-stopped run).
    case warning
    /// At least one item asked for was NOT written (skipped, failed, unreadable), or written but a follow-up step failed.
    case incomplete
    /// The action failed as a whole or was refused.
    case error
    /// Everything asked for was written, but the user must read this before carrying on (a step to do by hand, a change applied at next
    /// launch, an approximate result). Shown as an alert. `FeedbackClassifier` never returns it: a call site chooses it explicitly.
    case notice

    var presentation: FeedbackPresentation {
        switch self {
        case .done, .nothingToDo, .warning: return .toast
        case .incomplete, .error, .notice: return .alert
        }
    }
}

enum FeedbackPresentation: Equatable, Sendable {
    case toast
    case alert
}

/// An optional follow-up button on a result.
enum FeedbackAction: Equatable, Sendable {
    case revealInFinder([URL])

    var title: String { "Show in Finder" }
}

// MARK: - Feedback

/// One finished action's result, independent of how it is shown.
struct Feedback: Equatable, Sendable {
    var kind: FeedbackKind
    var title: String
    var message: String
    var action: FeedbackAction?

    init(kind: FeedbackKind, title: String, message: String, action: FeedbackAction? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.action = action
    }

    var presentation: FeedbackPresentation { kind.presentation }

    static func error(_ title: String, _ message: String) -> Feedback {
        Feedback(kind: .error, title: title, message: message)
    }

    /// A result that was fully written but must be read (an alert, never a toast).
    static func notice(_ title: String, _ message: String, action: FeedbackAction? = nil) -> Feedback {
        Feedback(kind: .notice, title: title, message: message, action: action)
    }
}

// MARK: - Classifier

enum FeedbackClassifier {
    /// The kind of a batch result. `written` = items actually written; `unchanged` = items already in the requested state; `notWritten` =
    /// skipped + failed; `caveats` = written-with-a-note counts. Order: anything not written is `.incomplete`; else any caveat is
    /// `.warning`; else nothing written is `.nothingToDo`; else `.done`. `unchanged` never changes the kind; it is kept so call sites
    /// state their counts.
    static func batch(written: Int, unchanged: Int = 0, notWritten: Int, caveats: Int = 0) -> FeedbackKind {
        if notWritten > 0 { return .incomplete }
        if caveats > 0 { return .warning }
        if written == 0 { return .nothingToDo }
        return .done
    }
}

// MARK: - Inbox

/// What a `feedbackAlert` does with the results a model hands it. A toast-kind result is passed straight on; an alert-kind result is shown,
/// and stays shown until the user acknowledges it: a later result (toast or alert) never takes it down, and later alerts wait their turn.
///
/// Rules for the models that feed it: a model writes its `feedback` ONCE per completed action (two writes in one run-loop turn are merged
/// by `onChange`, and only the last is seen). Alerts still waiting when the window closes are lost.
struct FeedbackInbox: Equatable {
    /// The alert on screen, if any.
    private(set) var presented: Feedback?
    /// Alerts that arrived while another was on screen (or while the next one was about to be shown), oldest first.
    private(set) var waiting: [Feedback] = []

    /// Takes a result. Returns it when it is a toast (the caller shows it); returns nil when it was kept as an alert.
    /// An alert identical to one already shown or waiting is dropped, so one failure reported twice is acknowledged once. While others
    /// wait, a new alert goes to the back of the line even if nothing is on screen at this instant (between `acknowledge` and `presentNext`).
    mutating func receive(_ feedback: Feedback) -> Feedback? {
        guard feedback.presentation == .alert else { return feedback }
        if presented == nil, waiting.isEmpty {
            presented = feedback
        } else if presented != feedback, !waiting.contains(feedback) {
            waiting.append(feedback)
        }
        return nil
    }

    /// Takes several results in order. Returns the toasts, in order; the alerts are kept exactly as `receive(_:)` keeps them.
    mutating func receive(all items: [Feedback]) -> [Feedback] {
        items.compactMap { receive($0) }
    }

    /// The user closed `feedback`. Does nothing when a different alert is on screen. The next waiting alert is NOT shown yet: see `presentNext()`.
    mutating func acknowledge(_ feedback: Feedback) {
        guard presented == feedback else { return }
        presented = nil
    }

    /// Shows the oldest waiting alert, when nothing is on screen. Called a moment after `acknowledge`, so the alert that is closing and the
    /// one that follows are two presentations.
    mutating func presentNext() {
        guard presented == nil, !waiting.isEmpty else { return }
        presented = waiting.removeFirst()
    }
}
