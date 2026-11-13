import Foundation

// MARK: - Activity item

/// One long-running action the activity strip lists (Export, Enhance, the folder import, the five Library tools). Pure: the strip only draws these.
struct ActivityItem: Equatable, Identifiable, Sendable {
    /// Declaration order is the strip's row order (`ActivityItem.ordered`).
    enum Kind: String, CaseIterable, Sendable { case export, enhance, importFolders, merge, xmp, trash, backup, importCopy }
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
            text: stopping ? "Stopping after this photo… \(completed) of \(total) done" : "Exporting \(completed) of \(total)…",
            progress: .steps(done: completed, total: total),
            canCancel: !stopping && completed + 1 < total
        )
    }

    /// Enhance is one atomic async call with no incremental progress, and cannot be stopped.
    static let enhancing = ActivityItem(kind: .enhance, text: "Enhancing…", progress: .indeterminate, canCancel: false)

    /// A folder import (scan + insert) has no incremental progress and cannot be stopped.
    static let importingFolders = ActivityItem(kind: .importFolders, text: "Importing photos…", progress: .indeterminate, canCancel: false)

    /// Photo Merge renders in one atomic call: no incremental progress, no stop.
    static let merging = ActivityItem(kind: .merge, text: "Merging photos…", progress: .indeterminate, canCancel: false)
    /// XMP read / write.
    static let workingOnXMP = ActivityItem(kind: .xmp, text: "Working on XMP files…", progress: .indeterminate, canCancel: false)
    /// Move to Trash.
    static let movingToTrash = ActivityItem(kind: .trash, text: "Moving photos to the Trash…", progress: .indeterminate, canCancel: false)
    /// Catalog backup write / check.
    static let workingOnBackup = ActivityItem(kind: .backup, text: "Working on the catalog backup…", progress: .indeterminate, canCancel: false)

    /// Copy Photos: a count while the total is known, else a plain indeterminate row. Not cancellable.
    static func copying(done: Int, total: Int) -> ActivityItem {
        total > 0
            ? ActivityItem(kind: .importCopy, text: "Copying photos… \(done) of \(total)", progress: .steps(done: done, total: total), canCancel: false)
            : ActivityItem(kind: .importCopy, text: "Copying photos…", progress: .indeterminate, canCancel: false)
    }

    /// Rows sorted into `Kind` order, one per kind (the last of two with the same kind wins).
    static func ordered(_ items: [ActivityItem]) -> [ActivityItem] {
        Kind.allCases.compactMap { kind in items.last { $0.kind == kind } }
    }

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
