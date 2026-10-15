import SwiftUI

/// The Library view — a thumbnail grid over every catalogued photo, backed
/// by `CatalogModel.photos`. Selecting a thumbnail hands the tapped
/// `Photo` back via `onOpen`; this view has no opinion on what happens
/// next (that's `ContentView`'s job — load it into the editor and switch
/// back to editing mode).
struct LibraryGridView: View {
    @ObservedObject var catalog: CatalogModel
    let onOpen: (Photo) -> Void

    /// D2 (IMPROVEMENTS.md): drives both the grid's column minimum and
    /// each cell's own frame size (see `LibraryThumbnailCell.cellSize`).
    /// `@AppStorage`, not `@State` — this view is torn down and recreated
    /// on every Editor↔Library switch (see `ThumbnailCache.swift`'s own
    /// doc comment), so a plain `@State` would silently reset the slider
    /// on every trip through the Editor. No `@AppStorage` precedent
    /// exists elsewhere in this app (its two `UserDefaults` uses are
    /// hand-rolled bookmark dictionaries, a different shape), but it's
    /// the standard tool for a single persisted scalar UI preference like
    /// this one. Capped at 240 — `ThumbnailCache`'s own decode size — so
    /// this never asks for a size the cache can't serve crisply; see
    /// `LibraryThumbnailCell`'s doc comment for why the cache itself is
    /// deliberately untouched.
    @AppStorage("PhotoApp.libraryThumbnailSize") private var thumbnailSize: Double = 140

    /// Single source of truth for the slider's bounds — reviewer-caught:
    /// the floor and the read-site/migration clamps below used to
    /// duplicate this range as separate literals, which a future range
    /// change could silently desync. The floor of 120 is only safe
    /// because `LibraryThumbnailCell`'s icon row was ALSO measured (twice
    /// — an earlier pass here overclaimed a "108pt" figure the reviewer
    /// then measured as actually 122pt, still ABOVE this floor) and
    /// tightened to a real, verified 116.0pt layout-minimum / 113pt
    /// visible-ink-minimum — see that cell's own `HStack` doc comment for
    /// the full numbers.
    private static let thumbnailSizeRange: ClosedRange<Double> = 120...240

    /// Clamped read of `thumbnailSize` — reviewer-caught: a value
    /// persisted from BEFORE the floor was raised from 100 to 120 must
    /// not render at the old, too-small size even on the very FIRST
    /// frame after an upgrade, before `.onAppear`'s migration below has
    /// had a chance to run. The `isFinite` guard (matching this
    /// codebase's own established habit, e.g. `EditSliderRow`'s typed-
    /// input fix) isn't reachable through `ThinSlider` itself — every one
    /// of its own code paths is already clamped/finite — only through a
    /// hand-corrupted `UserDefaults` value; `min(max(.nan, ...), ...)`
    /// would otherwise still be `.nan` and reach `.frame(width:)`.
    private var cellSize: Double {
        guard thumbnailSize.isFinite else { return Self.thumbnailSizeRange.lowerBound }
        return min(max(thumbnailSize, Self.thumbnailSizeRange.lowerBound), Self.thumbnailSizeRange.upperBound)
    }

    /// D4 (IMPROVEMENTS.md): the `ScrollView`'s own on-screen width — see
    /// its `.background(GeometryReader)` call site (in `body`) for why it's
    /// measured there rather than on the `LazyVGrid` itself. `0` until the
    /// first layout pass, which `LibraryGridColumns` treats as "1 column"
    /// rather than dividing by zero.
    @State private var gridWidth: Double = 0

    /// D4 (IMPROVEMENTS.md): one-shot guard for restoring scroll position
    /// to the focused cell when returning to the Library from the Editor
    /// (this view is torn down/rebuilt on every Editor↔Library switch —
    /// see `thumbnailSize`'s own doc comment above for the same lifecycle,
    /// so this genuinely resets each time, not "once ever"). Runs from the
    /// width `GeometryReader`'s own `.onAppear` rather than the
    /// `ScrollView`'s bare one purely so there's a single, obvious place
    /// that only ever fires once per Library visit — reviewer-verified
    /// (empirically, via an `NSHostingView` probe) that `ScrollViewProxy.
    /// scrollTo` itself resolves correctly against post-layout geometry
    /// regardless of which `.onAppear` triggers it, so this move fixed a
    /// theorized ordering issue that, measured, turned out not to be a
    /// real bug — it's a no-op behaviorally, kept for the cleaner call site.
    @State private var hasRestoredInitialScrollPosition = false

    private static let gridSpacing: Double = 12
    /// Explicit, not the parameterless `.padding()`'s platform default —
    /// reviewer-caught: `columnCount` below needs to subtract this exact
    /// amount from `gridWidth` (the pre-padding `ScrollView` frame), so an
    /// unverified assumption about what `.padding()` defaults to on macOS
    /// would silently desync the two.
    private static let gridPadding: Double = 16

    /// The single source of truth for how many columns the grid renders —
    /// see `LibraryGridColumns`'s own doc comment for why this replaced
    /// `GridItem(.adaptive(minimum:))`: an adaptive grid's own column count
    /// isn't obtainable from code, so Up/Down arrow navigation (added this
    /// session) would have nothing authoritative to jump by. `columns`
    /// below and the key-handling methods further down both read this SAME
    /// property, so the grid's layout and its keyboard math can't drift
    /// apart.
    ///
    /// Known, accepted imprecision: `gridWidth` is the `ScrollView`'s full
    /// frame, which doesn't subtract a legacy always-on vertical scroller
    /// (System Settings → General → "Show scroll bars: Always", ~15pt) —
    /// on that setting this can compute one column too many. Not corrected
    /// here; reviewer-measured (empirically) that this makes adjacent
    /// cells overlap by roughly `scrollerWidth / (columnCount + 1)` (~2pt
    /// for a typical column count), not merely "tighter" as an earlier
    /// version of this comment claimed — cosmetic, only when the pane
    /// width happens to sit within ~15pt of a column boundary, but a real
    /// (if small) visual artifact, not a purely internal number.
    private var columnCount: Int {
        // Clipped HERE, not just at `columns`' own `Array(repeating:count:)`
        // call site — reviewer-caught: the Up/Down key math further down
        // also reads `columnCount` directly, so clipping only at the array
        // site would leave the two desynced above the clip threshold. Both
        // now share the exact same number either way — unreachable in
        // real use (`LibraryGridColumns.count`'s own `1_000_000` ceiling
        // needs a ~132,000pt-wide window at this view's smallest cell
        // size), but genuinely one source of truth rather than two call
        // sites that happen to usually agree.
        min(
            LibraryGridColumns.count(
                forWidth: gridWidth - 2 * Self.gridPadding, cellSize: cellSize, spacing: Self.gridSpacing
            ),
            1000
        )
    }

    private var columns: [GridItem] {
        // D4 (IMPROVEMENTS.md): `.flexible(minimum: 1, maximum: cellSize)`,
        // not `.fixed(cellSize)` — reviewer-caught (empirically, via an
        // `NSHostingView` probe): `.fixed` columns give the `LazyVGrid` a
        // hard MINIMUM width that propagates upward through the
        // `ScrollView` to the window itself, creating a one-way layout
        // ratchet — enlarging the window (or dragging the sidebar
        // narrower) could grow `columnCount` but never let it shrink back,
        // since the grid would refuse to lay out narrower than its old
        // column count already demanded. `.flexible` has no such minimum
        // (it can compress down to `1`pt), so the `ScrollView`/window stay
        // freely resizable in both directions — `columnCount` remains the
        // one authoritative source `body`'s `GeometryReader` and the
        // Up/Down key math both read, only the GridItem flavor changed.
        // Every cell already pins its own `.frame(width: cellSize)`
        // (`LibraryThumbnailCell`, below) and centers within its column
        // regardless of the column's own width, so this is visually a
        // no-op — the same reasoning that applied to the original
        // `.adaptive`→`.fixed` switch. `columnCount`'s own `1000` clip
        // (defending against `LibraryGridColumns.count`'s documented
        // `1_000_000` pathological-input ceiling, a worse failure mode
        // here than the `Int` trap it exists to avoid) is applied there,
        // not re-applied here, so this and the Up/Down key math can't
        // desync above the clip threshold.
        Array(
            repeating: GridItem(.flexible(minimum: 1, maximum: cellSize), spacing: Self.gridSpacing),
            count: columnCount
        )
    }

    /// D5 (IMPROVEMENTS.md): the photo a "Remove from Library" tap is
    /// asking to confirm. Lives here, not `ContentView`, deliberately —
    /// `ContentView.body` was already split once specifically because a
    /// 5th `.alert` pushed the type-checker past its limit (see that
    /// file's own `mainContent` doc comment); a 6th alert there would risk
    /// the same failure again.
    @State private var photoPendingRemoval: Photo?

    /// D4 (IMPROVEMENTS.md): whether the grid itself (as opposed to the
    /// search field, a Picker, or a cell's own Button) currently owns
    /// keyboard focus — required for `.onKeyPress` below to fire at all.
    /// `.focusable()`/`.onKeyPress` are used here rather than the app's one
    /// existing low-level keyboard mechanism (`MetalImageView`'s
    /// `NSEvent` scroll monitor) deliberately: that monitor fires BEFORE
    /// SwiftUI's own focus dispatch, which is exactly wrong here — it would
    /// turn digits typed into `filterBar`'s search `TextField` into rating
    /// changes. `.onKeyPress` only fires while this container genuinely
    /// holds focus, so typing in the search field is naturally unaffected.
    @FocusState private var isGridFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Grid-scoped controls live here, not ContentView's main
            // toolbar — that toolbar is already crowded (Import Folder/
            // Import Folder Tree/Export/Compare), and these refine what
            // THIS view shows, not app-level actions.
            if !catalog.photos.isEmpty {
                filterBar
            }
            Group {
                let emptyKind = LibraryEmptyKind.of(isLoaded: catalog.isLoaded, photoCount: catalog.photoCount, shownCount: catalog.photos.count,
                                                      isCollectionSelected: Self.isCollection(catalog.selectedFilter),
                                                      openFailed: catalog.openFailureMessage != nil)
                if emptyKind == .openFailed {
                    CatalogOpenFailedView(message: catalog.openFailureMessage ?? "")
                } else if emptyKind == .loading {
                    // The catalog is still being read: show nothing rather than flashing "no photos".
                    Color.clear
                } else if emptyKind == .emptyLibrary {
                    LibraryEmptyLibraryView(catalog: catalog)
                } else if emptyKind == .emptyCollection {
                    LibraryEmptyCollectionView(isFolder: Self.isFolderCollection(catalog))
                } else if catalog.displayedPhotos.isEmpty {
                    noMatchesState
                } else {
                    // D4 (IMPROVEMENTS.md): the app's first `ScrollViewReader`
                    // over the Library grid (precedent: `EditorFilmstripView`'s
                    // filmstrip) — lets arrow-key focus changes below scroll
                    // the newly-focused cell into view.
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                                ForEach(catalog.displayedPhotos) { photo in
                                    LibraryThumbnailCell(
                                        catalog: catalog, photo: photo, cellSize: cellSize,
                                        isFocused: catalog.focusedPhotoPath == photo.path,
                                        thumbnailRevision: catalog.thumbnailRevisions[photo.path, default: 0]
                                    ) {
                                        onOpen(photo)
                                    } onRequestRemoval: {
                                        photoPendingRemoval = photo
                                    }
                                    .id(photo.path)
                                }
                            }
                            .padding(Self.gridPadding)
                        }
                        // D4 (IMPROVEMENTS.md): measures the SCROLL VIEW's
                        // own frame, not the `LazyVGrid`'s — reviewer-caught:
                        // `.fixed` columns (unlike `.adaptive`) give the grid
                        // an INTRINSIC width equal to its own column count,
                        // so a `.background(GeometryReader)` on the grid
                        // itself would measure a value that's a function of
                        // `columnCount`, which is a function of that same
                        // measurement — a circular fixed point with no
                        // connection to the pane's actual available width.
                        // The `ScrollView`'s own frame is sized by ITS
                        // parent (the `HSplitView` pane in `ContentView`),
                        // independent of its scrollable content, which
                        // breaks that circularity. `gridPadding` is
                        // subtracted explicitly in `columnCount` below,
                        // rather than relying on `.padding()`'s unverified
                        // default amount.
                        .background(
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear {
                                        gridWidth = geometry.size.width
                                        restoreInitialScrollPositionIfNeeded(proxy)
                                    }
                                    .onChange(of: geometry.size.width) { _, newWidth in gridWidth = newWidth }
                            }
                        )
                        // D4 (IMPROVEMENTS.md): reclaims grid keyboard focus
                        // on any click inside the scroll area — including a
                        // cell's own checkbox/star/flag/menu `Button`s, whose
                        // own tap can otherwise shift AppKit's key-view focus
                        // onto that specific control. `.simultaneousGesture`
                        // (not `.gesture` or `.onTapGesture`) runs ALONGSIDE
                        // those buttons' own taps rather than intercepting
                        // them, so this never blocks a rating/flag/menu tap.
                        .simultaneousGesture(TapGesture().onEnded { isGridFocused = true })
                        .onChange(of: catalog.focusedPhotoPath) { _, newPath in
                            if let newPath {
                                withAnimation { proxy.scrollTo(newPath, anchor: .center) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focusEffectDisabled()
            .focused($isGridFocused)
            .onKeyPress { keyPress in handleKeyPress(keyPress) }
            .onAppear { isGridFocused = true }
            if !catalog.photos.isEmpty {
                thumbnailSizeBar
            }
        }
        .alert(
            "Remove from Library?",
            isPresented: Binding(
                get: { photoPendingRemoval != nil },
                set: { isPresented in if !isPresented { photoPendingRemoval = nil } }
            ),
            presenting: photoPendingRemoval
        ) { photo in
            Button("Remove", role: .destructive) { catalog.removePhoto(photo) }
            Button("Cancel", role: .cancel) {}
        } message: { photo in
            Text("\"\(photo.filename)\" will be removed from the Library. The original file on disk is not affected.")
        }
        .onAppear {
            // Normalizes the STORED value on every appearance (this view
            // is torn down/rebuilt on every Editor↔Library switch, so
            // this genuinely re-runs each time, not "once ever" despite
            // reading like a one-time migration at a glance) — a value
            // persisted from BEFORE the slider's floor was raised from
            // 100 to 120 (live-caught cell-overlap bug) would otherwise
            // keep the STORED preference stuck out of range forever; the
            // slider itself only clamps where its THUMB is drawn, never
            // the stored value, and the `cellSize` computed property
            // above already covers every RENDER in the meantime, so this
            // is pure hygiene, not load-bearing for correctness. Guarded
            // so a value already in range doesn't trigger a redundant
            // `UserDefaults`/`objectWillChange` write on every single
            // Library visit. Writes back the already-clamped `cellSize`
            // (not a fresh `min(max(...))` recompute) — reviewer-caught:
            // recomputing independently here meant a corrupt NaN value
            // evaluated `min(max(.nan, ...), ...)` to NaN again (Swift's
            // `min`/`max` return their first argument when a NaN
            // comparison is false), so this guard's own "already in
            // range" check kept re-detecting the same corruption and
            // rewriting the same NaN back forever — the exact repeated
            // write this guard exists to prevent. Reusing `cellSize` also
            // removes a subtler divergence: for `+.infinity`, the old
            // recompute here normalized to 240 while `cellSize` (above)
            // separately normalized to 120, so the first frame and every
            // frame after `.onAppear` disagreed.
            let range = Self.thumbnailSizeRange
            if !thumbnailSize.isFinite || thumbnailSize < range.lowerBound || thumbnailSize > range.upperBound {
                thumbnailSize = cellSize
            }
        }
    }

    /// See `hasRestoredInitialScrollPosition`'s own doc comment for why
    /// this runs from the width `GeometryReader`'s `onAppear`, not the
    /// `ScrollView`'s.
    private func restoreInitialScrollPositionIfNeeded(_ proxy: ScrollViewProxy) {
        guard !hasRestoredInitialScrollPosition else { return }
        hasRestoredInitialScrollPosition = true
        if let path = catalog.focusedPhotoPath {
            proxy.scrollTo(path, anchor: .center)
        }
    }

    // MARK: - D4 (IMPROVEMENTS.md): keyboard navigation

    /// One dispatch point for every key the grid handles, binding
    /// `catalog.displayedPhotos` ONCE per event — the same "don't ask
    /// twice" discipline `PhotoAppApp.photoNeighbors` already documents,
    /// since this is a full filter+sort of the library on every access.
    /// Unhandled keys return `.ignored` so menu shortcuts (owned at the
    /// `Commands` level — see `PhotoAppApp.swift`'s one-owner-per-key-combo
    /// rule) and ordinary typing elsewhere are never intercepted.
    ///
    /// Reviewer-caught: bails immediately if ⌘/⌥/⌃ is held, so an unowned
    /// modified combo (⌘F, ⌥F, ⌃1…⌃5) never falls through to the plain-
    /// character branches below and silently flags/rates a photo — and
    /// ⌘←/⌘→ specifically fall all the way through to here while
    /// `showLibrary` is true, since `PhotoAppApp`'s own Photo-menu items
    /// are merely `.disabled` (not absent) in that state, and a disabled
    /// `NSMenuItem` doesn't consume the keystroke. Checking against this
    /// SPECIFIC "semantic" set, rather than subtracting an "allowed" set
    /// like Shift, is deliberate: macOS reports every arrow-key `NSEvent`
    /// as ALSO carrying `.numericPad`/`.function` regardless of any real
    /// modifier (an earlier version of this guard subtracted only
    /// `.shift`, which made it reject every arrow press outright — measured
    /// live: a plain Left-arrow's `KeyPress.modifiers` is `[.numericPad,
    /// .function]`, not empty), and `.function` is itself deprecated on
    /// macOS 12+. Checking `isDisjoint` against the three modifiers that
    /// actually change a key's MEANING sidesteps both problems and stays
    /// correct even if a future macOS attaches other incidental flags to
    /// arrow/character events.
    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let semanticModifiers: EventModifiers = [.command, .option, .control]
        guard keyPress.modifiers.isDisjoint(with: semanticModifiers) else { return .ignored }
        let displayed = catalog.displayedPhotos
        switch keyPress.key {
        case .leftArrow: return moveFocus(by: -1, in: displayed)
        case .rightArrow: return moveFocus(by: 1, in: displayed)
        case .upArrow: return moveFocus(by: -columnCount, in: displayed)
        case .downArrow: return moveFocus(by: columnCount, in: displayed)
        case .return: return openFocused(in: displayed)
        default: break
        }
        if let character = keyPress.characters.first, let command = PhotoKeyCommand.command(for: character) {
            switch command {
            case .rating(let digit): return setRatingOnFocused(digit, in: displayed)
            case .label(let label): return setLabelOnFocused(label, in: displayed)
            case .flag(let status): return setFlagOnFocused(status, in: displayed)
            }
        }
        return .ignored
    }

    /// Moves focus by `offset` positions in `photos` — `±1` for Left/Right,
    /// `±columnCount` for Up/Down, reusing `LibraryNavigation.neighbor(of:
    /// in:offset:)` as-is (it already takes an arbitrary offset over any
    /// `[Photo]` array; no changes needed there). When nothing is currently
    /// focused, or the focused path fell out of `photos` (filtered away,
    /// or the sidebar moved to a different Collection/Folder), any arrow
    /// press focuses the FIRST photo instead of moving relative to nothing
    /// — matching `LibraryNavigation`'s own "degrade safely, don't jump
    /// somewhere wrong" convention. Reaching a grid edge (an out-of-bounds
    /// offset) is a no-op, not a wraparound — same convention.
    ///
    /// Known, accepted limitation: Down from a row directly above a
    /// COLUMN THAT DOESN'T EXIST in a partial final row (fewer photos than
    /// `columnCount`) is one such out-of-bounds no-op — those trailing
    /// cells are only reachable via Left/Right, not Down. Not fixed this
    /// session; clamping Down to the last valid item would need its own
    /// care to avoid landing on an unintended row.
    private func moveFocus(by offset: Int, in photos: [Photo]) -> KeyPress.Result {
        guard !photos.isEmpty else { return .ignored }
        guard let currentPath = catalog.focusedPhotoPath,
              photos.contains(where: { $0.path == currentPath }) else {
            catalog.focusedPhotoPath = photos.first?.path
            return .handled
        }
        if let next = LibraryNavigation.neighbor(of: currentPath, in: photos, offset: offset) {
            catalog.focusedPhotoPath = next.path
        }
        return .handled
    }

    /// Return opens the focused photo — the exact same `onOpen` closure a
    /// mouse click on a cell already calls, so `ContentView.libraryContent`
    /// needs no changes to support this.
    private func openFocused(in photos: [Photo]) -> KeyPress.Result {
        guard let path = catalog.focusedPhotoPath, let photo = photos.first(where: { $0.path == path }) else {
            return .ignored
        }
        onOpen(photo)
        return .handled
    }

    private func setRatingOnFocused(_ rating: Int, in photos: [Photo]) -> KeyPress.Result {
        guard let path = catalog.focusedPhotoPath, let photo = photos.first(where: { $0.path == path }) else {
            return .ignored
        }
        catalog.setRating(rating, for: photo)
        advanceFocusIfNoLongerVisible(previousPath: path, previousList: photos)
        return .handled
    }

    /// `6`-`9` toggle red/yellow/green/blue: pressing the photo's current
    /// label's key clears it.
    private func setLabelOnFocused(_ label: ColorLabel, in photos: [Photo]) -> KeyPress.Result {
        guard let path = catalog.focusedPhotoPath, let photo = photos.first(where: { $0.path == path }) else {
            return .ignored
        }
        catalog.setColorLabel(photo.colorLabel.toggled(to: label), for: photo)
        advanceFocusIfNoLongerVisible(previousPath: path, previousList: photos)
        return .handled
    }

    /// `.`/`f` toggle Pick (a Rejected photo goes back to unflagged rather
    /// than straight to Picked); `p`/`x`/`u` set Pick/Reject/Unflag directly.
    private func setFlagOnFocused(_ status: FlagStatus?, in photos: [Photo]) -> KeyPress.Result {
        guard let path = catalog.focusedPhotoPath, let photo = photos.first(where: { $0.path == path }) else {
            return .ignored
        }
        catalog.setFlagStatus(status ?? photo.flagStatus.toggledPick, for: photo)
        advanceFocusIfNoLongerVisible(previousPath: path, previousList: photos)
        return .handled
    }

    /// Reviewer-caught: rating/flagging/labeling the focused photo can filter it
    /// OUT of `displayedPhotos` (e.g. rating it below `catalog.minimumRating`,
    /// unflagging it while `catalog.flagFilter` is `.picked`, or relabeling
    /// it while `catalog.labelFilter` is a different color) — without this,
    /// focus would silently keep pointing at a now-invisible photo until
    /// the next arrow press reset it all the way back to the grid's first
    /// item. Instead, moves focus to whichever photo now occupies the SAME
    /// position in the freshly re-filtered list — a sensible neighbor
    /// rather than a jump back to the start. A no-op when the photo is
    /// still visible (the overwhelmingly common case).
    private func advanceFocusIfNoLongerVisible(previousPath: String, previousList: [Photo]) {
        let freshList = catalog.displayedPhotos
        guard !freshList.contains(where: { $0.path == previousPath }) else { return }
        guard let previousIndex = previousList.firstIndex(where: { $0.path == previousPath }) else { return }
        let clampedIndex = min(previousIndex, freshList.count - 1)
        catalog.focusedPhotoPath = freshList.indices.contains(clampedIndex) ? freshList[clampedIndex].path : nil
    }

    private var filterBar: some View { LibraryFilterBar(catalog: catalog) }

    /// D2 (IMPROVEMENTS.md): bottom-right thumbnail-size slider, Photos'
    /// own convention. `ThinSlider`, this app's custom-styled slider
    /// (`Sources/UI/ThinSlider.swift`) — not the native SwiftUI `Slider`,
    /// which was deliberately replaced app-wide already because its
    /// glossy 3D knob doesn't restyle to match the flat dark theme.
    private var thumbnailSizeBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Image(systemName: "photo")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            // Floor raised from 100 to 120 alongside the cell-width fix
            // below (live-caught overlap bug) — this comment went through
            // two reviewer-caught inaccuracies before landing on real,
            // measured numbers, see the icon row's own `HStack` doc
            // comment for the full history: at the icon row's ORIGINAL
            // font sizes/spacing, 120 was measured as 9pt BELOW the
            // row's true minimum (actively insufficient, not "zero-slack"
            // as an earlier version of this exact comment claimed); the
            // `.caption2` icon shrink alone still left 120 above the
            // minimum; only tightening the row's own spacing (6→4) is
            // what actually brought the row under 120 with real margin.
            ThinSlider(
                value: $thumbnailSize,
                range: Self.thumbnailSizeRange,
                valueDescription: { "\(Int($0.rounded())) points" }
            )
                .frame(width: 100)
                .accessibilityLabel("Thumbnail size")
            Image(systemName: "photo")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private static func isFolderCollection(_ catalog: CatalogModel) -> Bool {
        guard case .collection(let id) = catalog.selectedFilter else { return false }
        return catalog.collections.first { $0.id == id }?.isFolder ?? false
    }

    private static func isCollection(_ filter: LibraryFilter) -> Bool {
        if case .collection = filter { return true }
        return false
    }

    /// Distinct from the empty-library / empty-collection screens (`EmptyStates.swift`) — photos EXIST for the current
    /// Collection/Folder selection, they just don't match the current
    /// sort/filter/search refinement. Without this distinction, a
    /// filtered-to-nothing grid would misleadingly look like an empty
    /// library.
    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text("No photos match")
                .font(.headline)
            Text("Try a different search or adjust the rating/flag/label/keyword filters.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Clear Filters") {
                catalog.clearLibraryFilters()
            }
            .buttonStyle(.flat)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `LibraryThumbnailCell`'s own `.task(id:)` key — path ALONE used to be
/// enough (a cell only ever needed to re-fetch when scrolled onto a
/// different photo), but a batch settings-paste can invalidate a cell's
/// thumbnail WHILE it's already on screen showing the SAME photo, which a
/// path-only key can't detect (SwiftUI only re-runs `.task(id:)` when the
/// id itself actually changes). Including `revision` makes a same-photo
/// invalidation a real identity change too.
private struct ThumbnailTaskKey: Equatable {
    let path: String
    let revision: Int
}

/// One grid cell: fetches its own thumbnail lazily (`.task(id:)`, keyed on
/// the photo's path AND its `thumbnailRevision` — see `ThumbnailTaskKey` —
/// so scrolling a recycled cell onto a different photo re-fetches, and so
/// does a same-photo revision bump from a batch settings paste).
/// `catalog` is `let`, not `@ObservedObject` here — this cell only ever
/// calls `catalog.thumbnail(for:)`, it doesn't need to re-render when
/// unrelated `@Published` properties change (which is exactly why
/// `thumbnailRevision` must be passed in from the PARENT rather than read
/// from `catalog` directly here — see that property's own doc comment).
///
/// D3 (IMPROVEMENTS.md): also checks for a sidecar file (`hasEdits`) in
/// the SAME `.task`, deliberately NOT inside `ThumbnailCache` itself —
/// the cache's `NSCache<NSString, CGImage>` and its other call site
/// (`EditorFilmstripView`'s `FilmstripCell`) both expect a bare
/// `CGImage?`; widening that shared return type would ripple into both
/// cells and every `ThumbnailCacheTests` call site for a check only this
/// cell needs. Still "amortized with the decode" in the sense that
/// matters — once per cell-appearance, not once per render — just done
/// at the view layer.
private struct LibraryThumbnailCell: View {
    let catalog: CatalogModel
    let photo: Photo
    let cellSize: CGFloat
    /// D4 (IMPROVEMENTS.md): the grid's keyboard-focused photo, passed down
    /// as a plain `let` rather than read from `catalog` in here — this
    /// struct deliberately keeps `catalog` a non-`@ObservedObject` `let`
    /// (see this type's own doc comment above) for the same reason
    /// `EditorFilmstripView`'s `FilmstripCell` receives `isCurrent` as a
    /// parameter instead of comparing against a published property itself.
    let isFocused: Bool
    /// `catalog.thumbnailRevisions[photo.path, default: 0]`, read and
    /// passed down by the PARENT grid view (which IS `@ObservedObject`),
    /// for the exact same reason `isFocused` is a parameter rather than a
    /// direct `catalog` read: this cell's own `catalog` is a plain `let`,
    /// so a change to `catalog.thumbnailRevisions` alone would never
    /// re-trigger this view's `body`/`.task(id:)` if read from `catalog`
    /// directly here. Bumped by `CatalogModel.invalidateThumbnail(for:)` —
    /// see `.task(id:)` below for why this needs to be part of the task's
    /// own identity, not just re-read inside an unchanged task.
    let thumbnailRevision: Int
    let onTap: () -> Void
    let onRequestRemoval: () -> Void

    @State private var image: CGImage?
    @State private var hasEdits = false
    /// D5 (IMPROVEMENTS.md): true only once `CatalogModel.isPhotoConfirmedMissing(_:)`
    /// confirms the file is genuinely gone — see its own doc comment for
    /// why a bare `fileExists` check alone isn't trustworthy (a
    /// sandbox-access hiccup would misreport as "deleted"). Computed
    /// UNCONDITIONALLY in `.task(id:)` below, not gated on the thumbnail
    /// decode failing — `ThumbnailCache` serves an already-cached
    /// thumbnail forever with no freshness check, so a photo viewed
    /// before its file was deleted would otherwise never re-fail the
    /// decode at all (caught live, after this looked correct in review).
    @State private var isMissing = false
    /// The pointer is over this cell (drives `CellChrome`'s dimming).
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                // D5 (IMPROVEMENTS.md): `isMissing` takes priority over a
                // cached `image` — `ThumbnailCache` serves a once-decoded
                // thumbnail forever with no freshness check (it has no way
                // to know the underlying file was later deleted), so a
                // photo viewed before its file vanished would otherwise
                // keep showing its stale cached thumbnail as if nothing
                // had changed. Caught live: `isMissing` is now computed
                // unconditionally in `.task(id:)` below, not gated on the
                // decode having failed, specifically because a cache HIT
                // means the decode never fails at all.
                // D6 (IMPROVEMENTS.md): wrapped so the thumbnail itself can
                // be ONE focusable "open" element, a sibling of the
                // selection checkbox `Button` below inside this same outer
                // `ZStack` — reviewer-caught: putting `.isButton` +
                // `.accessibilityAction` on the whole-cell container
                // instead (further down, `children: .contain`) doesn't
                // reliably work, since VoiceOver treats a `.contain`
                // container as something to navigate INTO, not activate.
                // Deliberately `ZStack`, not `Group` — reviewer-caught:
                // SwiftUI applies a `Group`'s modifiers to EACH of its
                // children individually, not to the group as a whole, so
                // this only happened to behave as one element because the
                // `if`/`else if`/`else` below always yields exactly one
                // child; `ZStack` is a real container view, so the "one
                // accessibility element" intent is structural, not
                // incidental on that branching staying single-view.
                ZStack {
                    if isMissing {
                        missingPlaceholder
                    } else if let image {
                        // `.frame(width:height:)` BEFORE `.clipShape` here is
                        // load-bearing, not cosmetic: without it, `.aspectRatio(
                        // contentMode: .fill)` reports a DIFFERENT (often much
                        // larger) size to the enclosing ZStack depending on
                        // each photo's own native aspect ratio. That was
                        // invisible with the ZStack's old default (.center)
                        // alignment, but once `alignment: .topLeading` was
                        // added (for the badge below), it caused the badge to
                        // sit at a different effective position per photo —
                        // caught live. Pinning the image's own reported size
                        // to exactly `cellSize` makes the ZStack's content box
                        // (and therefore "top-leading") consistent for every
                        // photo regardless of its native dimensions — and is
                        // exactly why the D3 edited-badge overlay below also
                        // waits until AFTER this same frame+clip.
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: cellSize, height: cellSize)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        // Feedback while the thumbnail decodes — most visible
                        // right after re-sorting, which scrambles which photos
                        // land in the LazyVGrid's currently-rendered window,
                        // so previously off-screen/uncached photos briefly
                        // show this instead of a silent blank box.
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: cellSize, height: cellSize)
                    }
                }
                .opacity(photo.flagStatus == .rejected ? 0.45 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(thumbnailAccessibilityLabel)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onTap() }
                // Always-present selection checkbox (dimmed at rest, see `CellChrome`) — tapping IT toggles
                // selection (a `Button` claims its own tap before the
                // cell's whole-VStack `.onTapGesture` below sees it, the
                // same already-proven pattern the star row/flag/menu
                // controls use); tapping anywhere else on the thumbnail
                // still opens the photo, unchanged.
                Button {
                    catalog.toggleSelection(of: photo)
                } label: {
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.35))
                            .frame(width: 22, height: 22)
                        Image(systemName: catalog.isSelected(photo) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                    // Dimmed (never hidden) until hover / selection: see `CellChrome`.
                    .opacity(CellChrome.checkOpacity(isHovered: isHovered, isSelected: catalog.isSelected(photo),
                                                     anySelected: !catalog.selectedPhotoIDs.isEmpty))
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("Select photo")
                .accessibilityAddTraits(catalog.isSelected(photo) ? [.isSelected] : [])
            }
            .frame(width: cellSize, height: cellSize)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if hasEdits {
                    editedBadge
                }
            }
            .overlay(alignment: .topTrailing) {
                if photo.colorLabel != .none {
                    Circle()
                        .fill(photo.colorLabel.color)
                        .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
                        .frame(width: 12, height: 12)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            // D4 (IMPROVEMENTS.md): the keyboard-focus ring — a full white outline around the cell, a different SHAPE from the
            // selection mark (a filled check in the corner), so "keyboard-focused" never reads as "export-selected". Same technique as
            // `EditorFilmstripView`'s current-photo ring (there at `Theme.selectedOutline`).
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white, lineWidth: isFocused ? 2 : 0)
            )

            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                // D6 (IMPROVEMENTS.md): the thumbnail element above already
                // carries `photo.filename` as its own accessibility label —
                // without this, VoiceOver would announce the filename twice
                // per cell (once as that button's label, once as this
                // visible caption).
                .accessibilityHidden(true)

            // `spacing: 4`, tightened from 6 — reviewer-measured (twice):
            // at `.body`-sized flag/folder icons and `spacing: 6`, this
            // row's true minimum was 129.0pt layout / 126pt visible-ink;
            // shrinking those two icons to `.caption2` (below) dropped
            // that to 122.0pt/119pt — STILL above the slider's 120pt
            // floor, an overclaimed "~108pt" in an earlier version of
            // this fix that the reviewer caught was simply wrong. `spacing:
            // 4` is what actually buys real margin: 116.0pt layout /
            // 113pt visible-ink, i.e. 4pt/7pt of slack under the 120
            // floor — the number `.clipped()`'s own doc comment below
            // needs to be true for "backstop, not load-bearing" to hold.
            HStack(spacing: 4) {
                StarRatingRow(rating: photo.rating) { newRating in
                    catalog.setRating(newRating, for: photo)
                }
                Spacer(minLength: 0)
                Button {
                    catalog.setFlagStatus(photo.flagStatus.toggledPick, for: photo)
                } label: {
                    // `.caption2`, matching `StarRatingRow`'s own icon
                    // size — see the `HStack`'s own doc comment above for
                    // the measured effect.
                    Image(systemName: photo.flagStatus.symbolName)
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(photo.flagStatus.tint)
                .accessibilityLabel("Flag")
                .accessibilityValue(photo.flagStatus.accessibilityValue)
                // D6 (IMPROVEMENTS.md): `accessibilityValue` (above)
                // carries the three states (Picked/Rejected/Unflagged).
                // `.isSelected` is kept for Picked only, for continuity
                // with the selection checkbox's own D6 idiom.
                .accessibilityAddTraits(photo.flagStatus == .picked ? [.isSelected] : [])

                Menu {
                    ForEach(catalog.collections) { collection in
                        Button {
                            catalog.toggleMembership(of: photo, in: collection)
                        } label: {
                            let isMember = catalog.membershipsByPhotoID[photo.id ?? -1, default: []]
                                .contains(collection.id ?? -1)
                            HStack {
                                Text(collection.name)
                                Spacer()
                                if isMember {
                                    Image(systemName: "checkmark")
                                }
                            }
                            // D6 (IMPROVEMENTS.md): the checkmark above is
                            // glyph-only, so membership state is invisible
                            // to VoiceOver reading this menu item — fold it
                            // into the item's own label instead.
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(isMember ? "\(collection.name), member" : collection.name)
                        }
                    }
                    if !catalog.collections.isEmpty {
                        Divider()
                    }
                    ForEach(FlagStatus.menuOrder, id: \.self) { status in
                        Button {
                            catalog.setFlagStatus(status, for: photo)
                        } label: {
                            HStack {
                                Text(status.menuTitle)
                                Spacer()
                                if photo.flagStatus == status {
                                    Image(systemName: "checkmark")
                                }
                            }
                            // D6 (IMPROVEMENTS.md): same fix as the
                            // collection items above — the checkmark is
                            // glyph-only, so fold the current state into
                            // the item's label for VoiceOver.
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                photo.flagStatus == status ? "\(status.menuTitle), current" : status.menuTitle
                            )
                        }
                    }
                    Divider()
                    ForEach(ColorLabel.menuOrder, id: \.self) { label in
                        Button {
                            catalog.setColorLabel(label, for: photo)
                        } label: {
                            HStack {
                                Text(label.menuTitle)
                                Spacer()
                                if photo.colorLabel == label {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                photo.colorLabel == label ? "\(label.menuTitle), current" : label.menuTitle
                            )
                        }
                    }
                    if isMissing {
                        Divider()
                        Button {
                            Task { await catalog.relocatePhoto(photo) }
                        } label: {
                            Label("Locate…", systemImage: "questionmark.folder")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        onRequestRemoval()
                    } label: {
                        // `role: .destructive` alone doesn't render red text
                        // on a macOS `Menu` item the way it does in an
                        // `.alert` — caught live (the alert's own Remove
                        // button DID render correctly). Explicit red tint
                        // added so the destructive action actually reads as
                        // dangerous, not just semantically marked as such.
                        Label {
                            Text("Remove from Library")
                                .foregroundStyle(.red)
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                // Reviewer-caught: a macOS `Menu`'s built-in disclosure
                // indicator isn't accounted for in the row-width
                // measurement above at all — hiding it removes the
                // uncertainty entirely rather than trying to measure a
                // glyph whose presence/size isn't guaranteed.
                .menuIndicator(.hidden)
                .accessibilityLabel("Photo options")
            }
            // Dimmed (never hidden, never resized) until hover / selection / focus, unless the photo carries a rating, flag or label:
            // see `CellChrome`. Opacity keeps the measured width budget, the hit areas and VoiceOver exactly as they were.
            .opacity(CellChrome.rowOpacity(
                isHovered: isHovered, isSelected: catalog.isSelected(photo), isFocused: isFocused,
                hasRatingFlagOrLabel: photo.rating > 0 || photo.flagStatus != .none || photo.colorLabel != .none))
        }
        // Live-caught: only the thumbnail `ZStack` above constrained its
        // own width to `cellSize` — the outer VStack (filename + the
        // star/flag/folder row below it) had no width constraint of its
        // own at all, so at the slider's smallest sizes the icon row's
        // fixed-size content (5 star buttons + flag + folder menu, none
        // of which can compress below their own minimum size) needed more
        // width than one grid column actually had, and SwiftUI let it
        // paint past the cell's own bounds into the NEXT cell's column —
        // exactly the "folder icon overlaps the next photo's star row"
        // report. `.clipped()` alone isn't the real fix — the actual fix
        // is constraining the whole cell, not just the thumbnail, to
        // `cellSize`, AND measuring (not guessing) that the row's content
        // genuinely fits inside the slider's floor with real margin.
        // Measured twice by the reviewer: `.body`-sized flag/folder icons
        // at `spacing: 6` needed 129.0pt layout / 126pt visible-ink —
        // above the 120pt floor entirely; shrinking those two icons to
        // `.caption2` alone only got to 122.0pt/119pt — STILL above the
        // floor (an earlier version of this fix's doc comments claimed
        // "~108pt" here, which was simply wrong); tightening the row's
        // own `HStack` spacing from 6 to 4 is what actually buys margin:
        // 116.0pt layout / 113pt visible-ink, 4pt/7pt of slack under 120.
        // `.clipped()` stays anyway, purely as a backstop so a future,
        // even-narrower addition to this row degrades to a clipped edge
        // within its OWN cell, never bleeding into a neighbor again.
        .frame(width: cellSize)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // D4 (IMPROVEMENTS.md): reviewer-caught — without this, mouse
        // interaction never wrote `catalog.focusedPhotoPath` at all, so
        // clicking a DIFFERENT cell's checkbox/star/flag (none of which
        // open the photo) left the keyboard's notion of "focused" pointing
        // at whatever was last arrow-key-focused, possibly scrolled off-
        // screen — a subsequent rating/flag keypress would then silently
        // mutate the WRONG photo. `.simultaneousGesture` (not `.gesture`,
        // which would compete with the checkbox/star/flag `Button`s' own
        // taps) runs alongside them, so any click anywhere in this cell —
        // including on those controls — also focuses this cell's own
        // photo; live-verified for the checkbox/star/flag buttons and a
        // plain cell-body tap. NOT independently verified for the `Menu`
        // specifically — macOS opens a `Menu` on mouse-DOWN into its own
        // native tracking loop, which is harder to probe than a plain
        // `Button` tap; expected to behave the same way but flagged here
        // rather than silently assumed.
        .simultaneousGesture(TapGesture().onEnded { catalog.focusedPhotoPath = photo.path })
        // D6 (IMPROVEMENTS.md): `children: .contain` (not `.combine`/
        // `.ignore`) keeps the star rating/flag/menu/checkbox/thumbnail
        // below individually reachable as child elements, rather than
        // collapsing the whole cell into one opaque element. Reviewer-
        // caught: a `.contain` container is something VoiceOver navigates
        // INTO, not something it activates — so the "open" label/trait/
        // action live on the thumbnail element above instead (a focusable
        // child, sibling to the checkbox `Button`), not here. No explicit
        // label on the container itself either, to avoid double-announcing
        // `photo.filename` (it's both the thumbnail child's label AND the
        // visible `Text(photo.filename)` row below, both already children).
        .accessibilityElement(children: .contain)
        .onHover { isHovered = $0 }
        .task(id: ThumbnailTaskKey(path: photo.path, revision: thumbnailRevision)) {
            // Reset immediately: a reused cell carries over `@State` from
            // whatever photo it PREVIOUSLY showed (same as `image`/
            // `hasEdits` below), and a stale "Missing" is more alarming
            // than a stale thumbnail.
            isMissing = false
            isHovered = false // a recycled cell must not inherit the previous photo's hover
            // `async let` so the cheap synchronous sidecar stat below
            // doesn't serialize behind either of these two slower async
            // calls.
            async let thumbnail = catalog.thumbnail(for: photo)
            // Computed UNCONDITIONALLY, not gated on the decode failing —
            // caught live: `ThumbnailCache` serves an already-decoded
            // thumbnail forever with no freshness check, so a photo
            // viewed before its file was deleted keeps "succeeding" at
            // decode (from cache) even though the file is long gone. The
            // decode failing was never a reliable signal for "missing" on
            // its own; it only happened to look that way in this
            // session's earlier testing because nothing had been cached
            // yet for the deleted photo.
            async let missingCheck = catalog.isPhotoConfirmedMissing(photo)
            let sidecarURL = ImageDocumentModel.sidecarURL(for: URL(fileURLWithPath: photo.path))
            hasEdits = FileManager.default.fileExists(atPath: sidecarURL.path)
            let thumb = await thumbnail
            let missing = await missingCheck
            // A superseded `.task` (this cell recycled onto a different
            // photo, OR re-triggered by a `thumbnailRevision` bump on the
            // SAME photo, before these awaits returned) must not write ITS
            // stale result over the newer in-flight task — neither
            // `catalog.thumbnail(for:)` nor `isPhotoConfirmedMissing(_:)`
            // checks `Task.isCancelled` internally (`ThumbnailCache`'s own
            // doc comment covers why for the decode), so this guard is
            // this cell's only defense against that race. Load-bearing,
            // not defense-in-depth, for the revision case specifically: a
            // batch settings-paste bumping `thumbnailRevision` on a photo
            // whose decode is ALREADY mid-flight is exactly the scenario
            // this guard exists to catch — see `ThumbnailCache.
            // generation`'s own doc comment for the matching actor-side
            // generation guard this pairs with.
            guard !Task.isCancelled else { return }
            image = thumb
            isMissing = missing
        }
    }

    /// The thumbnail's one VoiceOver label: filename, plus "missing" and/or
    /// the color label so the dot (which is hidden from AT) isn't lost.
    private var thumbnailAccessibilityLabel: String {
        var parts = [photo.filename]
        if isMissing { parts.append("missing") }
        if photo.colorLabel != .none { parts.append(photo.colorLabel.accessibilityName) }
        return parts.joined(separator: ", ")
    }

    /// D5 (IMPROVEMENTS.md): replaces a stale/indefinite thumbnail state
    /// once `CatalogModel.isPhotoConfirmedMissing(_:)` confirms the file
    /// is genuinely gone — see `.task(id:)` above.
    private var missingPlaceholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.warning)
            Text("Missing")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(width: cellSize, height: cellSize)
    }

    /// D3 (IMPROVEMENTS.md): same circular-backdrop visual language the
    /// selection checkbox above already uses, for consistency.
    private var editedBadge: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.35))
                .frame(width: 22, height: 22)
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundStyle(.white)
        }
        .padding(6)
        // D6 (IMPROVEMENTS.md): explicit `.accessibilityElement` rather
        // than relying on label propagation up from the `Image` child —
        // matches every other element in this file's own new pattern.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Edited")
    }
}

/// A row of 5 tappable stars, matching this app's existing "row of small
/// tappable icons" style (the aspect-ratio preset list and Selective
/// Color band swatches in `ContentView.swift`). Tapping the star that's
/// already the current rating clears it to 0 — the standard Lightroom/
/// Photos toggle-off convenience.
struct StarRatingRow: View {
    let rating: Int
    let onSet: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onSet(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(star <= rating ? Theme.markOn : Theme.textSecondary)
            }
        }
        // D6 (IMPROVEMENTS.md): without this, VoiceOver sees 5 separate,
        // identically-named "star"/"star fill" buttons per grid cell with
        // no indication of the current rating. `children: .ignore` collapses
        // them into ONE adjustable element instead — mouse/tap behavior
        // (including the tap-current-star-to-clear convenience above) is
        // completely untouched, this only changes what the accessibility
        // tree reports.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "No rating" : "\(rating) of 5 stars")
        .accessibilityAdjustableAction { direction in
            // Reviewer-caught: guard the bounds rather than clamping
            // unconditionally — `onSet(rating)` at either end would fire a
            // redundant `catalog.setRating` write (DB round-trip +
            // `@Published` mutation) for a genuine no-op, the same phantom-
            // write class `EditSliderRow`'s `seedText` guard exists to
            // prevent. The mouse path never hits this either (tapping the
            // current star toggles to 0, it doesn't re-set the same value).
            switch direction {
            case .increment: if rating < 5 { onSet(rating + 1) }
            case .decrement: if rating > 0 { onSet(rating - 1) }
            @unknown default: break
            }
        }
    }
}
