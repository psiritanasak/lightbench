import SwiftUI

/// A collapsible horizontal strip of Library thumbnails along the bottom of
/// the Editor (IMPROVEMENTS.md D1(b), the follow-on to D1(a)'s ⌘←/⌘→
/// commands) — lets the user browse between photos with the mouse without
/// leaving the Editor, Lightroom/Photos-style. A separate `View` type
/// rather than inlined into `ContentView.editorContent`, mainly for
/// organization — NOT a guaranteed invalidation-scope win: `onSelect` is a
/// fresh closure built on every `ContentView` body pass, so this view is
/// non-`Equatable` and SwiftUI can't prove it unchanged when unrelated
/// state (e.g. `document.editState`, on every slider tick) publishes; its
/// `body` likely still re-runs then. The cost of that is small regardless
/// (`LazyHStack` diffing over `catalog.displayedPhotos` is cheap, each
/// `FilmstripCell`'s `.task(id:)` only re-fires if `photo.path` changes,
/// and `@State private var image` persists across re-renders), so this
/// wasn't worth chasing further — see the D1(b) review that caught this
/// doc comment overclaiming the guarantee.
struct EditorFilmstripView: View {
    @ObservedObject var catalog: CatalogModel
    let currentURL: URL?
    let onSelect: (Photo) -> Void

    private let cellSize: CGFloat = 56

    var body: some View {
        // First `ScrollViewReader` use in this codebase: scrolls the strip
        // to keep the current photo in view whether it changed via a
        // filmstrip tap OR via ⌘←/⌘→ (both funnel through
        // `ImageDocumentModel.load(from:)`, which is the sole writer of
        // `currentURL`).
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(catalog.displayedPhotos) { photo in
                        FilmstripCell(
                            catalog: catalog,
                            photo: photo,
                            isCurrent: photo.path == currentURL?.path,
                            cellSize: cellSize,
                            onTap: { onSelect(photo) }
                        )
                        .id(photo.path)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onAppear {
                if let path = currentURL?.path {
                    proxy.scrollTo(path, anchor: .center)
                }
            }
            .onChange(of: currentURL) { _, newURL in
                if let path = newURL?.path {
                    withAnimation {
                        proxy.scrollTo(path, anchor: .center)
                    }
                }
            }
        }
        .frame(height: cellSize + 16)
        .background(Color(white: 0.11))
    }
}

/// A single filmstrip thumbnail. Intentionally much lighter than
/// `LibraryThumbnailCell` (`LibraryGridView.swift`) — no rating/flag/
/// filename/selection-checkbox, those are Library-grid management
/// concerns. Fetches through the exact same
/// `catalog.thumbnail(for:)` path `LibraryThumbnailCell` uses, so it
/// shares that actor's cache — anything the Library grid already decoded
/// is a free hit here, and this cell's on-screen size is well under the
/// cache's own 240px decode size, so it never forces a re-decode either.
private struct FilmstripCell: View {
    let catalog: CatalogModel
    let photo: Photo
    let isCurrent: Bool
    let cellSize: CGFloat
    let onTap: () -> Void

    @State private var image: CGImage?
    /// D5 (IMPROVEMENTS.md): mirrors `LibraryThumbnailCell`'s own field —
    /// same underlying "decode fails forever" bug, same gated check.
    @State private var isMissing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
            if image == nil {
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .frame(width: cellSize, height: cellSize)
                        .accessibilityLabel("Missing")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: cellSize, height: cellSize)
                }
            }
            if let image {
                // `.frame` BEFORE `.clipShape` — same load-bearing ordering
                // as `LibraryThumbnailCell` (see its own doc comment):
                // without it, `.aspectRatio(.fill)` reports a different
                // size per photo's native aspect ratio, which would throw
                // off the current-photo border below.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cellSize, height: cellSize)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(width: cellSize, height: cellSize)
        .clipped()
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: isCurrent ? 2 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: photo.path) {
            // Reset immediately — see `LibraryThumbnailCell`'s own
            // `.task(id:)` for why a reused cell must not carry over the
            // previous photo's `isMissing` value.
            isMissing = false
            let decoded = await catalog.thumbnail(for: photo)
            image = decoded
            if decoded == nil {
                isMissing = await catalog.isPhotoConfirmedMissing(photo)
            }
        }
    }
}
