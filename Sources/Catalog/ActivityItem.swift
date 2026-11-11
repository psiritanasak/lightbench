import Foundation

// MARK: - Activity item

/// One long-running action the activity strip lists (Export, Enhance). Pure: the strip only draws these.
struct ActivityItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case export, enhance, importFolders }
    enum Progress: Equatable, Sendable {
        case indeterminate
        case steps(done: Int, total: Int)
    }

    let kind: Kind
    var id: Kind { kind }
    var text: String
    var progress: Progress
    /// Whether the strip shows a Cancel button for this item.
    var canCancel: Bool

    // MARK: Builders

    /// `completed` = photos FINISHED (the same meaning as `ExportProgress.completed`): 0 while the first photo is in flight, so the photo
    /// in flight has index `completed`. A stop is only honoured BETWEEN photos, so Cancel is offered only while at least one photo is still
    /// waiting after the one in flight: `completed + 1 < total`. On the last photo (or when finished) there is nothing left to stop, and
    /// while already stopping a second request means nothing.
    static func export(completed: Int, total: Int, stopping: Bool) -> ActivityItem {
        ActivityItem(
            kind: .export,
            text: stopping ? "Stopping after this photo… \(completed) of \(total) exported" : "Exporting \(completed) of \(total)…",
            progress: .steps(done: completed, total: total),
            canCancel: !stopping && completed + 1 < total
        )
    }

    /// Enhance is one atomic async call with no incremental progress, and cannot be stopped.
    static let enhancing = ActivityItem(kind: .enhance, text: "Enhancing…", progress: .indeterminate, canCancel: false)

    /// A folder import (scan + insert) has no incremental progress and cannot be stopped.
    static let importingFolders = ActivityItem(kind: .importFolders, text: "Importing photos…", progress: .indeterminate, canCancel: false)

    /// What the strip lists, in order: Export, Enhance, folder import.
    static func strip(
        export: (completed: Int, total: Int)?, stopping: Bool, enhancing: Bool, importingFolders: Bool
    ) -> [ActivityItem] {
        var items: [ActivityItem] = []
        if let export { items.append(.export(completed: export.completed, total: export.total, stopping: stopping)) }
        if enhancing { items.append(.enhancing) }
        if importingFolders { items.append(.importingFolders) }
        return items
    }
}
