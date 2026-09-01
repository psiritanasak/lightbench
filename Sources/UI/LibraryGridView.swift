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

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)] }

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
                                LibraryThumbnailCell(catalog: catalog, photo: photo, cellSize: thumbnailSize) {
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
            ThinSlider(value: $thumbnailSize, range: 100...240)
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

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                if image == nil {
                    // Feedback while the thumbnail decodes — most visible
                    // right after re-sorting, which scrambles which photos
                    // land in the LazyVGrid's currently-rendered window,
                    // so previously off-screen/uncached photos briefly
                    // show this instead of a silent blank box.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: cellSize, height: cellSize)
                }
                if let image {
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

            HStack(spacing: 6) {
                StarRatingRow(rating: photo.rating) { newRating in
                    catalog.setRating(newRating, for: photo)
                }
                Spacer(minLength: 0)
                Button {
                    catalog.setFlagged(!photo.isFlagged, for: photo)
                } label: {
                    Image(systemName: photo.isFlagged ? "flag.fill" : "flag")
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
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: photo.path) {
            // `async let` so the cheap synchronous sidecar stat doesn't
            // serialize behind the (much slower) thumbnail decode.
            async let thumbnail = catalog.thumbnail(for: photo)
            let sidecarURL = ImageDocumentModel.sidecarURL(for: URL(fileURLWithPath: photo.path))
            hasEdits = FileManager.default.fileExists(atPath: sidecarURL.path)
            image = await thumbnail
        }
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
