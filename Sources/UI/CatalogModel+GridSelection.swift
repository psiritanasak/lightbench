import Foundation

/// The Library grid's click / keyboard selection, applied to the model (`GridSelection` holds the rules).
extension CatalogModel {
    // MARK: - Applying outcomes

    /// Writes an outcome: selection (only if it changed), anchor, and focus (only if it differs).
    func applyGridOutcome(_ outcome: GridSelection.Outcome) {
        setSelection(outcome.selection)
        gridSelectionAnchor = outcome.anchor
        if focusedPhotoPath != outcome.focusKey { focusedPhotoPath = outcome.focusKey }
    }

    /// A plain click / plain arrow: exactly this cell.
    func selectOnlyGridCell(_ item: StackGridItem) {
        applyGridOutcome(GridSelection.selectingOnly(item))
    }

    /// Shift-click / Shift-arrow: selects the range from the anchor (or the focus) to `cells[index]` and focuses it.
    /// Returns false (nothing changed) when there is no usable start or `index` is out of range.
    @discardableResult
    func extendGridSelection(toCellAt index: Int, in cells: [StackGridItem]) -> Bool {
        guard let outcome = GridSelection.extending(to: index, in: cells, selection: selectedPhotoIDs,
                                                    anchor: gridSelectionAnchor, focusKey: focusedPhotoPath) else { return false }
        applyGridOutcome(outcome)
        return true
    }

    /// Select All: every photo of every cell (hidden stack members included); focus stays.
    func selectAllGridCells(in cells: [StackGridItem]) {
        setSelection(GridSelection.allIDs(in: cells))
        gridSelectionAnchor = nil
    }

    /// Clears the selection. Returns false when nothing was selected (the caller can then leave the key unhandled).
    @discardableResult
    func clearGridSelection() -> Bool {
        guard !selectedPhotoIDs.isEmpty else { return false }
        clearSelection()
        return true
    }
}
