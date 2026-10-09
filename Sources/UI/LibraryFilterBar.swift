import SwiftUI

/// The Library's filter bar: Sort, Rating, Flag, Label and Keyword pop-ups (showing only their current value — the options say what each
/// is) and the search field. A filter that is away from its default sits on a grey chip, and a small clear button appears only while any
/// filter is active (sort alone never counts). Extracted from `LibraryGridView` so it can be rendered in tests.
struct LibraryFilterBar: View {
    @ObservedObject var catalog: CatalogModel

    private func chip(_ isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(isActive ? Theme.selectedFill : Color.clear)
    }

    var body: some View {
        let state = catalog.libraryFilterState
        HStack(spacing: 12) {
            Picker("Sort", selection: $catalog.sortOption) {
                ForEach(LibrarySortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Sort")
            .frame(maxWidth: 140)

            Picker("Rating", selection: $catalog.minimumRating) {
                Text("Any Rating").tag(0)
                ForEach(1...5, id: \.self) { stars in
                    Text(String(repeating: "★", count: stars) + "+").tag(stars)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Rating")
            .frame(maxWidth: 110)
            .background(chip(state.isRatingActive))

            Picker("Flag", selection: $catalog.flagFilter) {
                ForEach(LibraryFlagFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Flag")
            .frame(maxWidth: 130)
            .background(chip(state.isFlagActive))

            Picker("Label", selection: $catalog.labelFilter) {
                ForEach(LibraryLabelFilter.allCases) { option in
                    if let label = option.colorLabel, let swatch = LabelSwatch.image(for: label) {
                        Label { Text(option.label) } icon: { Image(nsImage: swatch) }.tag(option)
                    } else {
                        Text(option.label).tag(option)
                    }
                }
            }
            .labelsHidden()
            .accessibilityLabel("Label")
            .frame(maxWidth: 130)
            .background(chip(state.isLabelActive))

            Picker("Keyword", selection: $catalog.keywordFilterID) {
                Text("All Keywords").tag(Int64?.none)
                let counts = catalog.keywordPhotoCounts
                ForEach(catalog.keywords) { keyword in
                    Text("\(keyword.name) (\(counts[keyword.id ?? -1, default: 0]))").tag(keyword.id)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Keyword")
            .frame(maxWidth: 150)
            .background(chip(state.isKeywordActive))

            if state.isActive {
                Button {
                    catalog.clearFiltersKeepingSort()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Clear filters")
                .accessibilityLabel("Clear filters")
            }

            Spacer(minLength: 12)

            TextField("Search filename or keyword…", text: $catalog.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
