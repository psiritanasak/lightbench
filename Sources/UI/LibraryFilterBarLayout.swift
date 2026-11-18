import CoreGraphics
import Foundation

/// Pure layout rules for the Library filter bar (A5): the width constants of its full row, and which of its two rows (full, or
/// collapsed with one "Filters" menu) fits a given width. Foundation/CoreGraphics only.
///
/// The view's `ViewThatFits` is the runtime switch; `mode(forWidth:showsPeople:)` is its exact PREDICTION, valid because every child
/// of the full row has a constant ideal width. A render test (batch 3) keeps the two equal.
///
/// Every constant below is a PROPOSAL, not a measurement: batch 3's render test pins them to the real view (and may change them).
enum LibraryFilterBarLayout {
    /// Left and right padding of the bar.
    static let horizontalPadding: CGFloat = 12
    /// Gap between the children of the row.
    static let spacing: CGFloat = 12
    /// The fixed slot of an icon button (search help / warning, Clear).
    static let iconSlot: CGFloat = 18
    /// The search field's ideal AND minimum width in the full row (equal on purpose: `ViewThatFits` measures ideal sizes).
    static let searchIdealWidth: CGFloat = 220
    static let searchMaxWidth: CGFloat = 420
    /// The search field's minimum width in the collapsed row.
    static let searchCollapsedMinWidth: CGFloat = 140

    static let ratingWidth: CGFloat = 110
    static let flagWidth: CGFloat = 130
    static let labelWidth: CGFloat = 130
    static let keywordWidth: CGFloat = 150
    static let personWidth: CGFloat = 140

    enum Mode: Equatable {
        case full
        case collapsed
    }

    /// The full row's ideal width: 2 x padding + search + help slot + the pop-ups + Clear slot + one gap between each pair of children.
    /// Children: search, help slot, a zero-width Spacer (it still takes a gap), Rating, Flag, Label, Keyword, [Person], Clear slot.
    static func fullRowWidth(showsPeople: Bool) -> CGFloat {
        var widths: [CGFloat] = [searchIdealWidth, iconSlot, 0, ratingWidth, flagWidth, labelWidth, keywordWidth]
        if showsPeople { widths.append(personWidth) }
        widths.append(iconSlot)
        let gaps = CGFloat(widths.count - 1) * spacing
        return 2 * horizontalPadding + widths.reduce(0, +) + gaps
    }

    /// `.full` exactly when the width holds the full row, else `.collapsed`. Depends on nothing but the width and whether People exist.
    static func mode(forWidth width: CGFloat, showsPeople: Bool) -> Mode {
        width >= fullRowWidth(showsPeople: showsPeople) ? .full : .collapsed
    }

    /// The Filters menu's title: "Filters", or "Filters (n)" while n > 0 filters inside it are active.
    static func filtersTitle(count: Int) -> String {
        count > 0 ? "Filters (\(count))" : "Filters"
    }

    /// The Filters menu's VoiceOver value.
    static func filtersAccessibilityValue(count: Int) -> String {
        count > 0 ? "\(count) active" : "none active"
    }
}
