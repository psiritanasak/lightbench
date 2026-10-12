import SwiftUI

/// The Library's filter bar: Sort, Rating, Flag, Label and Keyword pop-ups (showing only their current value — the options say what each
/// is) and the search field. A filter that is away from its default sits on a grey chip, and a small clear button appears only while any
/// filter is active (sort alone never counts). Extracted from `LibraryGridView` so it can be rendered in tests.
struct LibraryFilterBar: View {
    @ObservedObject var catalog: CatalogModel
    @State private var showingSearchHelp = false

    /// The one-line status next to the search field: an unreadable term wins over the scan progress, and the progress only
    /// shows when it matters (the query needs camera data, or none has been read yet).
    static func hint(forSearch text: String, scanStatus: String?, hasAnyMetadata: Bool) -> (text: String, isWarning: Bool)? {
        let query = SearchQuery(parsing: text)
        if let bad = query.invalidTerms.first { return ("Can't read \"\(bad)\"", true) }
        if let status = scanStatus, query.usesCameraData || !hasAnyMetadata { return (status, false) }
        return nil
    }

    private var searchHint: (text: String, isWarning: Bool)? {
        Self.hint(forSearch: catalog.searchText, scanStatus: catalog.metadataScanStatusText,
                  hasAnyMetadata: !catalog.metadataByPhotoID.isEmpty)
    }

    private func chip(_ isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(isActive ? Theme.selectedFill : Color.clear)
    }

    var body: some View {
        let state = catalog.libraryFilterState
        VStack(alignment: .trailing, spacing: 0) {
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

                // Only when the catalog has people (the People sheet makes them); a hidden person is left out, unless it is the active filter.
                let visiblePeople = catalog.people.filter { !$0.isHidden || $0.id == catalog.personFilterID }
                if !visiblePeople.isEmpty {
                    Picker("Person", selection: $catalog.personFilterID) {
                        Text("All People").tag(Int64?.none)
                        ForEach(visiblePeople) { person in
                            Text("\(person.displayName) (\(person.photoCount))").tag(Int64?.some(person.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Person")
                    .frame(maxWidth: 140)
                    .background(chip(state.isPersonActive))
                }

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

                TextField("Search name, keyword or iso:>800 camera:d610…", text: $catalog.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Search")

                Button { showingSearchHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Search syntax")
                .accessibilityLabel("Search syntax help")
                .popover(isPresented: $showingSearchHelp, arrowEdge: .bottom) { SearchHelpView() }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            // Scan progress, or why the query shows nothing (an unreadable field value). Its own line: the picker row is too tight
            // to share (measured live: inline it was squeezed to zero width).
            if let hint = searchHint {
                Text(hint.text)
                    .font(.caption)
                    .foregroundStyle(hint.isWarning ? Theme.warning : Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .accessibilityLabel(hint.text)
            }
        }
    }
}

/// The search syntax popover.
struct SearchHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search").font(.headline).foregroundStyle(Theme.textPrimary)
            ForEach(SearchHelp.rows, id: \.field) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.example).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 150, alignment: .leading)
                    Text(row.meaning).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(SearchHelp.note).font(.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true).frame(width: 340, alignment: .leading).padding(.top, 4)
        }
        .padding(14)
    }
}
