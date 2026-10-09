import SwiftUI

/// What the editor remembers across tab switches (the "safe set"): the sidebar's scroll offset per tab, and the selected retouch spot and
/// Point Color instance. Pure value logic so it is unit-tested; `ContentView` owns one and applies it.
///
/// Deliberately NOT remembered: armed modes (their discard-on-leave cleanup relies on being disarmed) and the selected MASK (its overlay,
/// Escape routing and zoom gates read the selection alone, and re-selecting it needs `select(_:)`'s side effects — see `EditorTab.switchEffects`).
/// Selections are written to the stash only by the tab that OWNS them, so deselecting on the owner tab and leaving forgets it, and a
/// pass through a non-owner tab never overwrites it.
struct TabMemory: Equatable {
    private(set) var scrollOffsets: [EditorTab: Double] = [:]
    private(set) var retouchSpotID: UUID?
    private(set) var pointColorID: UUID?

    // MARK: Scroll

    /// Stores `offset` for `tab`; a non-finite value is ignored and a negative one (overscroll bounce) is stored as 0.
    mutating func recordScroll(_ offset: Double, for tab: EditorTab) {
        guard offset.isFinite else { return }
        scrollOffsets[tab] = max(0, offset)
    }

    func scrollOffset(for tab: EditorTab) -> Double { scrollOffsets[tab] ?? 0 }

    /// The distance scrolled from the top EDGE, as `ScrollPosition(y:)` expects it, from a scroll geometry's `contentOffset.y` and top
    /// content inset. The geometry's offset is measured from ABOVE the inset (it is `-inset` at rest), so replaying it raw lands one inset
    /// short — live-measured 2026-10-09: the Editor sidebar came back exactly the window's title-bar height (52 pt) too high.
    static func scrollDistance(contentOffsetY: Double, topInset: Double) -> Double {
        guard contentOffsetY.isFinite, topInset.isFinite else { return 0 }
        return max(0, contentOffsetY + topInset)
    }

    // MARK: Selections

    /// Called when LEAVING `tab` with the selections as they were before the switch clears them: only the owning tab writes its entry.
    mutating func stash(leaving tab: EditorTab, retouchSpotID: UUID?, pointColorID: UUID?) {
        if tab == .retouch { self.retouchSpotID = retouchSpotID }
        if tab == .adjust { self.pointColorID = pointColorID }
    }

    /// The spot to re-select on entering the Retouch tab: only if it still exists, Compare is off and the geometry is at identity
    /// (otherwise the spot would count as "being edited" with no circles drawn, and Delete / Escape could act on it unseen).
    func restoredRetouchSpotID(existing: [UUID], compareIsOff: Bool, geometryAtIdentity: Bool) -> UUID? {
        guard compareIsOff, geometryAtIdentity, let id = retouchSpotID, existing.contains(id) else { return nil }
        return id
    }

    /// The Point Color instance to re-select on entering Adjust: only if it still exists.
    func restoredPointColorID(existing: [UUID]) -> UUID? {
        guard let id = pointColorID, existing.contains(id) else { return nil }
        return id
    }

    /// A different photo: nothing carries over.
    mutating func reset() { self = TabMemory() }
}

// MARK: - Scroll position memory (macOS 15+)

extension View {
    /// Gives the sidebar `ScrollView` a per-tab scroll offset: a new scroll view per tab (`.id`), starting at that tab's remembered offset,
    /// recording the offset when a scroll SETTLES (idle phase) — never from layout changes, so a tab whose content is shorter than a
    /// remembered offset cannot overwrite it by clamping. `ScrollPosition` / `onScrollPhaseChange` are macOS 15; on 14 this does
    /// nothing (every tab opens at the top, as before; and there is no `.id`, so view identity differs between the OS versions — harmless
    /// today, nothing in the sidebar views keeps `@State` across tabs). Known limit: a momentum scroll interrupted by a tab switch never
    /// reaches `.idle`, so that tab keeps its previous remembered offset. Pure SwiftUI: no `NSScrollView` access (see the history note on
    /// the sidebar scroll view).
    @ViewBuilder
    func tabScrollMemory(tab: EditorTab, memory: Binding<TabMemory>) -> some View {
        if #available(macOS 15.0, *) {
            self.modifier(RememberedScrollModifier(tab: tab, memory: memory)).id(tab)
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct RememberedScrollModifier: ViewModifier {
    let tab: EditorTab
    @Binding var memory: TabMemory
    @State private var position: ScrollPosition

    init(tab: EditorTab, memory: Binding<TabMemory>) {
        self.tab = tab
        _memory = memory
        // A tab with nothing remembered starts at the top EDGE (not an explicit y of 0): the sidebar relies on `.defaultScrollAnchor(.top)`
        // being honoured, and an edge cannot be off by a content inset.
        let offset = memory.wrappedValue.scrollOffset(for: tab)
        _position = State(initialValue: offset > 0 ? ScrollPosition(y: CGFloat(offset)) : ScrollPosition(edge: .top))
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollPhaseChange { oldPhase, newPhase, context in
                if newPhase == .idle, oldPhase != .idle {
                    memory.recordScroll(
                        TabMemory.scrollDistance(contentOffsetY: Double(context.geometry.contentOffset.y),
                                                 topInset: Double(context.geometry.contentInsets.top)),
                        for: tab)
                }
            }
    }
}
