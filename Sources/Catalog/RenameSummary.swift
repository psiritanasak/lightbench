import Foundation

/// The text and kind of Library "Rename Files…" and "Undo Rename" results. Pure, so the kinds and texts are testable without a model.
/// A rename is all-or-nothing (`RenameApplier`), so a finished rename or undo is a toast; every refusal or failure is an alert.
enum RenameSummary {
    static let title = "Rename"

    private static func plural(_ count: Int) -> String { "photo\(count == 1 ? "" : "s")" }

    /// A fully applied rename.
    static func renamed(count: Int) -> Feedback {
        Feedback(
            kind: FeedbackClassifier.batch(written: count, notWritten: 0), title: title,
            message: "Renamed \(count) \(plural(count)). Use Undo Rename to put the names back."
        )
    }

    /// A fully undone rename.
    static func restored(count: Int) -> Feedback {
        Feedback(
            kind: FeedbackClassifier.batch(written: count, notWritten: 0), title: title,
            message: "Restored \(count) \(plural(count)) to their previous names."
        )
    }

    /// A refusal or failure: nothing (or not everything) asked for was written.
    static func failure(_ message: String) -> Feedback { .error(title, message) }
}
