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

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cellSize), spacing: 12)] }

    /// D5 (IMPROVEMENTS.md): the photo a "Remove from Library" tap is
    /// asking to confirm. Lives here, not `ContentView`, deliberately —
    /// `ContentView.body` was already split once specifically because a
    /// 5th `.alert` pushed the type-checker past its limit (see that
    /// file's own `mainContent` doc comment); a 6th alert there would risk
    /// the same failure again.
    @State private var photoPendingRemoval: Photo?

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
                if catalog.photos.isEmpty {
                    emptyState
                } else if catalog.displayedPhotos.isEmpty {
                    noMatchesState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(catalog.displayedPhotos) { photo in
                                LibraryThumbnailCell(catalog: catalog, photo: photo, cellSize: cellSize) {
                                    onOpen(photo)
                                } onRequestRemoval: {
                                    photoPendingRemoval = photo
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Sort", selection: $catalog.sortOption) {
                ForEach(LibrarySortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .frame(maxWidth: 160)

            Picker("Rating", selection: $catalog.minimumRating) {
                Text("Any Rating").tag(0)
                ForEach(1...5, id: \.self) { stars in
                    Text(String(repeating: "★", count: stars) + "+").tag(stars)
                }
            }
            .frame(maxWidth: 130)

            Button {
                catalog.flaggedOnly.toggle()
            } label: {
                Image(systemName: catalog.flaggedOnly ? "flag.fill" : "flag")
            }
            .buttonStyle(.bordered)
            .foregroundStyle(catalog.flaggedOnly ? .yellow : .secondary)
            .help("Flagged only")

            Spacer(minLength: 12)

            TextField("Search filename…", text: $catalog.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

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
                .foregroundStyle(.secondary)
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
            ThinSlider(value: $thumbnailSize, range: Self.thumbnailSizeRange)
                .frame(width: 100)
            Image(systemName: "photo")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No photos imported yet")
                .font(.headline)
            Text("Use \u{201c}Import Folder\u{2026}\u{201d} in the toolbar to add photos to your library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Distinct from `emptyState` — photos EXIST for the current
    /// Collection/Folder selection, they just don't match the current
    /// sort/filter/search refinement. Without this distinction, a
    /// filtered-to-nothing grid would misleadingly look like an empty
    /// library.
    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No photos match")
                .font(.headline)
            Text("Try a different search or adjust the rating/flag filters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear Filters") {
                catalog.clearLibraryFilters()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One grid cell: fetches its own thumbnail lazily (`.task(id:)`, keyed on
/// the photo's path so scrolling a recycled cell onto a different photo
/// re-fetches). `catalog` is `let`, not `@ObservedObject` here — this cell
/// only ever calls `catalog.thumbnail(for:)`, it doesn't need to
/// re-render when unrelated `@Published` properties change.
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
                // Always-visible selection checkbox — tapping IT toggles
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
                            .foregroundStyle(catalog.isSelected(photo) ? Color.accentColor : .white)
                    }
                }
                .buttonStyle(.plain)
                .padding(6)
            }
            .frame(width: cellSize, height: cellSize)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if hasEdits {
                    editedBadge
                }
            }

            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

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
                    catalog.setFlagged(!photo.isFlagged, for: photo)
                } label: {
                    // `.caption2`, matching `StarRatingRow`'s own icon
                    // size — see the `HStack`'s own doc comment above for
                    // the measured effect.
                    Image(systemName: photo.isFlagged ? "flag.fill" : "flag")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(photo.isFlagged ? .yellow : .secondary)

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
                .foregroundStyle(.secondary)
                // Reviewer-caught: a macOS `Menu`'s built-in disclosure
                // indicator isn't accounted for in the row-width
                // measurement above at all — hiding it removes the
                // uncertainty entirely rather than trying to measure a
                // glyph whose presence/size isn't guaranteed.
                .menuIndicator(.hidden)
            }
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
        .task(id: photo.path) {
            // Reset immediately: a reused cell carries over `@State` from
            // whatever photo it PREVIOUSLY showed (same as `image`/
            // `hasEdits` below), and a stale "Missing" is more alarming
            // than a stale thumbnail.
            isMissing = false
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
            // photo before these awaits returned) must not write ITS
            // stale result over the NEW photo's own in-flight task —
            // neither `catalog.thumbnail(for:)` nor
            // `isPhotoConfirmedMissing(_:)` checks `Task.isCancelled`
            // internally (`ThumbnailCache`'s own doc comment covers why
            // for the decode), so this guard is this cell's only defense
            // against that race. `photo.path` driving `.task(id:)` means
            // a cell only recycles onto a genuinely different path, so
            // this is defense-in-depth, not a routinely-hit case.
            guard !Task.isCancelled else { return }
            image = thumb
            isMissing = missing
        }
    }

    /// D5 (IMPROVEMENTS.md): replaces a stale/indefinite thumbnail state
    /// once `CatalogModel.isPhotoConfirmedMissing(_:)` confirms the file
    /// is genuinely gone — see `.task(id:)` above.
    private var missingPlaceholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            Text("Missing")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
    }
}

/// A row of 5 tappable stars, matching this app's existing "row of small
/// tappable icons" style (the aspect-ratio preset list and Selective
/// Color band swatches in `ContentView.swift`). Tapping the star that's
/// already the current rating clears it to 0 — the standard Lightroom/
/// Photos toggle-off convenience.
private struct StarRatingRow: View {
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
                .foregroundStyle(star <= rating ? .yellow : .secondary)
            }
        }
    }
}
