import Foundation

/// The progress rows the five Library tools (Merge, XMP, Trash, Catalog Backup, Copy Photos) put in the window's activity strip. Owned by
/// `CatalogModel` but NOT published through it: only `FeedbackHostModifier` observes this object, so a copied photo redraws the strip and
/// nothing else (`ContentView` observes neither this nor the tool models). Each tool's dialog modifier reports its model's `activityItem`.
@MainActor
final class ActivityCenter: ObservableObject {
    @Published private(set) var items: [ActivityItem] = []

    /// Sets (or, with `nil`, clears) the row of one kind. Rows stay in `ActivityItem.Kind` order.
    func set(_ kind: ActivityItem.Kind, _ item: ActivityItem?) {
        var next = items.filter { $0.kind != kind }
        if let item { next.append(item) }
        next = ActivityItem.ordered(next)
        if next != items { items = next }
    }
}
