import SwiftUI

/// The Library view — a thumbnail grid over every catalogued photo, backed
/// by `CatalogModel.photos`. Selecting a thumbnail hands the tapped
/// `Photo` back via `onOpen`; this view has no opinion on what happens
/// next (that's `ContentView`'s job — load it into the editor and switch
/// back to editing mode).
struct LibraryGridView: View {
    @ObservedObject var catalog: CatalogModel
    let onOpen: (Photo) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        Group {
            if catalog.photos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(catalog.photos) { photo in
                            LibraryThumbnailCell(catalog: catalog, photo: photo) {
                                onOpen(photo)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

/// One grid cell: fetches its own thumbnail lazily (`.task(id:)`, keyed on
/// the photo's path so scrolling a recycled cell onto a different photo
/// re-fetches). `catalog` is `let`, not `@ObservedObject` here — this cell
/// only ever calls `catalog.thumbnail(for:)`, it doesn't need to
/// re-render when unrelated `@Published` properties change.
private struct LibraryThumbnailCell: View {
    let catalog: CatalogModel
    let photo: Photo
    let onTap: () -> Void

    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 140, height: 140)
            .clipped()

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
            image = await catalog.thumbnail(for: photo)
        }
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
