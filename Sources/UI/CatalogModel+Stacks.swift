import Foundation

/// Photo stacks in the Library (`StackPlanner` / `StackDisplay` / `StackSelection` are the pure parts; the database writes live in
/// `CatalogDatabase+Stacks`).
///
/// Stacking is a VIEW over the flat list, never a filter on it: `displayedPhotos` stays the flat, filtered and sorted list that Export's
/// empty-selection fallback, Trash, Rename, Keywords, Merge, XMP and every scan read, so those tools IGNORE stacking (a collapsed stack's
/// hidden members are still in them). Three places fold it into cells: the Library GRID (`gridPhotos`), the Editor filmstrip with ⌘←/⌘→
/// (`filmstripItems`) and Cull (`CullSession`, which stacks `displayedPhotos` itself).
extension CatalogModel {
    // MARK: - What the grid draws

    /// The grid's cells: one per collapsed stack, plus every other photo. Expanded stacks are shown as a CONTIGUOUS run of their visible
    /// members at the position of the stack's FIRST visible member in `displayedPhotos` — even under a non-date sort, where the members
    /// would otherwise be scattered, so an expanded stack never looks like several unrelated photos.
    var gridPhotos: [StackGridItem] {
        StackDisplay.apply(displayed: displayedPhotos, stacks: stacks, expandedIDs: expandedStackIDs)
    }

    /// The photos of the grid's cells, in cell order: what keyboard focus, arrow movement, scroll-to and "advance focus" walk. A photo
    /// hidden inside a collapsed stack is not a cell, so it can never hold keyboard focus.
    var gridCellPhotos: [Photo] { gridPhotos.map(\.photo) }

    /// The Editor filmstrip's cells (also what ⌘←/⌘→ walk): the grid's cells, except that the stack of the OPEN photo is expanded here (so
    /// the open photo is always a cell of its own, never hidden behind a collapsed stack). The grid's `expandedStackIDs` is not changed.
    func filmstripItems(openEditKey: String?) -> [StackGridItem] {
        let displayed = displayedPhotos
        // No stacks: every photo is its own cell (cheap path; the view and ⌘←/⌘→ build this on every body pass).
        if stacks.isEmpty {
            return displayed.map { StackGridItem(photo: $0, role: .plain, stackID: nil, visibleMembers: [], hiddenMemberCount: 0, isCover: false) }
        }
        var expanded = expandedStackIDs
        if let openEditKey, !stackByMasterID.isEmpty, let open = displayed.first(where: { $0.editKey == openEditKey }), let owner = stack(of: open) {
            expanded.insert(owner.id)
        }
        return StackDisplay.apply(displayed: displayed, stacks: stacks, expandedIDs: expanded)
    }

    // MARK: - Stack state

    /// Replaces the stacks (and drops expanded flags of stacks that no longer exist).
    func setStacks(_ newStacks: [StackSnapshot]) {
        stacks = newStacks
        var byMaster: [Int64: StackSnapshot] = [:]
        for stack in newStacks { for member in stack.memberIDs { byMaster[member] = stack } }
        stackByMasterID = byMaster
        let alive = Set(newStacks.map(\.id))
        if !expandedStackIDs.isSubset(of: alive) { expandedStackIDs.formIntersection(alive) }
        normalizeFocus()
    }

    // MARK: - Focus

    /// Where keyboard focus belongs now: a focused photo hidden inside a collapsed stack resolves to that stack's cell (`StackFocus`).
    /// ONE rule for the focus ring, the arrows, Return, the photo keys and scroll-to.
    func resolvedFocusPath(in items: [StackGridItem]) -> String? { StackFocus.resolve(focusedPhotoPath, in: items) }

    /// Moves focus off a hidden member onto its stack's cell. Run after anything that can hide the focused photo: stacks changing, a
    /// collapse, an Auto Stack apply, leaving Cull. `items` lets a caller that already built the cells avoid building them twice.
    func normalizeFocus(in items: [StackGridItem]? = nil) {
        guard let key = focusedPhotoPath else { return }
        if items == nil {
            // Cheap early-outs (the same answer as the full resolve, without filtering and sorting the whole library): a photo that is in
            // no stack, or whose stack is expanded, is its own cell.
            guard !stackByMasterID.isEmpty, let focused = photos.first(where: { $0.editKey == key }),
                  let owner = stack(of: focused), !expandedStackIDs.contains(owner.id) else { return }
        }
        let resolved = resolvedFocusPath(in: items ?? gridPhotos)
        if resolved != focusedPhotoPath { focusedPhotoPath = resolved }
    }

    /// The stack `photo` belongs to (a virtual copy belongs to its master's stack).
    func stack(of photo: Photo) -> StackSnapshot? {
        guard let id = photo.masterId ?? photo.id else { return nil }
        return stackByMasterID[id]
    }

    /// Local-first mirror of what the database does when masters leave the library: they drop out of their stacks, a stack left with fewer
    /// than two members disappears, and a stack whose cover left has no cover.
    func pruneStacks(removingMasters removed: Set<Int64>) {
        guard !removed.isEmpty, stacks.contains(where: { $0.memberIDs.contains(where: removed.contains) }) else { return }
        var result: [StackSnapshot] = []
        for var stack in stacks {
            stack.memberIDs.removeAll(where: removed.contains)
            if let cover = stack.coverPhotoID, removed.contains(cover) { stack.coverPhotoID = nil }
            if stack.memberIDs.count >= 2 { result.append(stack) }
        }
        setStacks(result)
    }

    /// Re-reads the stacks (a failed read keeps the previous ones).
    func reloadStacks() async {
        guard let database, let loaded = try? await database.allStacks() else { return }
        setStacks(loaded)
    }

    // MARK: - Expand / collapse

    /// Expands or collapses a stack. Collapsing while a hidden member holds keyboard focus moves the focus to the stack's cell (its
    /// cover), so the focus never points at a photo that is no longer a cell.
    func toggleExpanded(stackID: Int64) {
        if expandedStackIDs.contains(stackID) {
            expandedStackIDs.remove(stackID)
            normalizeFocus()
        } else {
            expandedStackIDs.insert(stackID)
        }
    }

    // MARK: - Selection of cells

    /// A collapsed stack's cell reads as selected only when ALL its visible members are (`StackSelection`).
    func isSelected(_ item: StackGridItem) -> Bool { StackSelection.isSelected(item, in: selectedPhotoIDs) }

    /// `.partial` when only some of a collapsed stack's visible members are selected: the checkbox then shows a mixed mark.
    func selectionState(of item: StackGridItem) -> StackSelection.State { StackSelection.state(of: item, in: selectedPhotoIDs) }

    /// Ticking a collapsed stack's cell selects every visible member; any other cell is its own photo.
    func toggleSelection(of item: StackGridItem) {
        let ids = StackSelection.ids(for: item)
        if isSelected(item) { deselect(ids) } else { select(ids) }
    }

    // MARK: - Manual stack operations

    /// Stacks the selected photos. Like Edit Keywords it acts on the WHOLE selection, including photos the current filters hide, and says
    /// so. Selecting a collapsed stack's cover already selected its members, so stacking two covers merges the two stacks.
    func stackSelected() async {
        guard let database else { return }
        let selected = selectedPhotos
        let masters = Set(selected.compactMap { $0.masterId ?? $0.id })
        guard masters.count >= 2 else { importStatusMessage = "Select at least two photos to stack."; return }
        let hidden = hiddenSelectionCount(selected)
        // Other stacks that lose members to this one: one left with a single photo ceases to exist (the database dissolves it).
        var dissolved = 0
        for other in Set(masters.compactMap { stackByMasterID[$0]?.id }) {
            guard let stack = stacks.first(where: { $0.id == other }) else { continue }
            if stack.memberIDs.filter({ !masters.contains($0) }).count == 1 { dissolved += 1 }
        }
        do {
            let created = try await database.createStack(photoIDs: selected.compactMap(\.id), manual: true)
            await reloadStacks()
            if created == nil {
                importStatusMessage = "Couldn't stack those photos."
            } else if hidden > 0 || dissolved > 0 {
                var parts = ["Stacked \(masters.count) photos"]
                if hidden > 0 { parts.append("including \(hidden) hidden by the current filters") }
                var message = parts.joined(separator: ", ") + "."
                if dissolved > 0 {
                    message += " \(dissolved) other stack\(dissolved == 1 ? " was" : "s were") left with a single photo and dissolved."
                }
                importStatusMessage = message
            }
        } catch {
            importStatusMessage = "Couldn't stack the photos: \(error.localizedDescription)"
        }
    }

    /// Takes the SELECTED photos out of their stacks (counted per original). A stack left with fewer than two photos ends with them, so
    /// the usual case (a collapsed stack's cover is selected = all its members are) dissolves it, while members that are not selected
    /// stay stacked. The photos taken out are remembered: Auto Stack will not stack them again until the sheet forgets them.
    func unstackSelected() async {
        guard let database else { return }
        let selected = selectedPhotos
        let selectedMasters = Set(selected.compactMap { $0.masterId ?? $0.id })
        var touched: [Int64: StackSnapshot] = [:]
        for photo in selected { if let owner = stack(of: photo) { touched[owner.id] = owner } }
        let leaving = selectedMasters.intersection(Set(touched.values.flatMap(\.memberIDs)))
        guard !leaving.isEmpty else { importStatusMessage = "None of the selected photos is in a stack."; return }
        let dissolved = touched.values.filter { $0.memberIDs.filter { !leaving.contains($0) }.count < 2 }
        let stranded = dissolved.reduce(0) { $0 + $1.memberIDs.filter { !leaving.contains($0) }.count }
        do {
            _ = try await database.removeFromStack(photoIDs: Array(leaving))
            await reloadStacks()
            var message = "Removed \(leaving.count) photo\(leaving.count == 1 ? "" : "s") from their stacks"
            if !dissolved.isEmpty {
                message += "; \(dissolved.count) stack\(dissolved.count == 1 ? "" : "s") ended"
                if stranded > 0 { message += " (\(stranded) remaining photo\(stranded == 1 ? " is" : "s are") no longer stacked)" }
            }
            importStatusMessage = message + ". Auto Stack will not stack the removed photos again."
        } catch {
            importStatusMessage = "Couldn't unstack the photos: \(error.localizedDescription)"
        }
    }

    /// Makes `photo` its stack's cover (a copy makes its master the cover).
    func makeCover(_ photo: Photo) async {
        guard let database, let id = photo.id, let owner = stack(of: photo) else { return }
        do { _ = try await database.setCover(stackID: owner.id, photoID: id) } catch {
            importStatusMessage = "Couldn't change the cover: \(error.localizedDescription)"
        }
        await reloadStacks()
    }

    /// Takes `photo` (its master) out of its stack; a stack left with one photo disappears. Remembered like Unstack.
    func removeFromStack(_ photo: Photo) async {
        guard let database, let id = photo.id else { return }
        do { _ = try await database.removeFromStack(photoIDs: [id]) } catch {
            importStatusMessage = "Couldn't remove the photo from its stack: \(error.localizedDescription)"
        }
        await reloadStacks()
    }

    /// Selected photos the current filters hide (what the batch disclosure counts).
    private func hiddenSelectionCount(_ selected: [Photo]) -> Int {
        let visible = Set(displayedPhotos.compactMap(\.id))
        return selected.filter { $0.id.map { !visible.contains($0) } ?? false }.count
    }

    // MARK: - Auto Stack

    /// The photos an Auto Stack run looks at: the ones the Library SHOWS (filters and search apply), masters only (virtual copies follow
    /// their master's stack).
    var autoStackScopePhotos: [Photo] { displayedPhotos.filter { !$0.isVirtualCopy } }

    /// Starts the Auto Stack scan. Refuses while a rename is in progress (it moves files under the scan), like the duplicate scan.
    func beginAutoStackScan() {
        guard !isRenameInProgress else { autoStack.statusMessage = Self.renameInProgressMessage; return }
        guard let database else { autoStack.statusMessage = "The photo catalog isn't ready yet — try again in a moment."; return }
        autoStack.begin(photos: autoStackScopePhotos, metadata: metadataByPhotoID, database: database)
    }

    /// Writes the previewed stacks, then re-reads the Library.
    func applyAutoStack() async {
        guard let database else { return }
        await autoStack.apply(database: database) { [weak self] in
            await self?.refresh()
            self?.normalizeFocus()
        }
    }

    func forgetUnstackedPhotos() async {
        guard let database else { return }
        await autoStack.forgetUnstacked(database: database)
    }
}
