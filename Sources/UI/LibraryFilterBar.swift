import SwiftUI

/// The Library's filter bar, one fixed-height row: the search field first (with the search-help / warning button beside it), then
/// fixed-width Rating, Flag, Label and Keyword pop-ups (and Person when the catalog has people; they show only their current value),
/// then a Clear slot that is always reserved (invisible while idle, so the width never depends on the filters). A filter away from its
/// default sits on a grey chip hugging its pop-up; sort alone never counts. When the row does not fit, `ViewThatFits` swaps it for a
/// collapsed row: search, help, one "Filters" menu holding the same filters as submenus, and the Clear slot
/// (`LibraryFilterBarLayout.mode(forWidth:showsPeople:)` predicts which row fits). Extracted from `LibraryGridView` so it can be rendered in tests.
struct LibraryFilterBar: View {
    @ObservedObject var catalog: CatalogModel
    @State private var showingSearchHelp = false

    /// The one-line status next to the search field: an unreadable term wins over the scan progress, and the progress only
    /// shows when it matters (the query needs camera data, or none has been read yet).
    /// `savedQuery` is the selected smart collection's own search: its camera-data terms also need the scan to be done.
    static func hint(forSearch text: String, scanStatus: String?, hasAnyMetadata: Bool, savedQuery: String = "") -> (text: String, isWarning: Bool)? {
        let query = SearchQuery(parsing: text)
        if let bad = query.invalidTerms.first { return ("Can't read \"\(bad)\"", true) }
        let needsCameraData = query.usesCameraData || SearchQuery(parsing: savedQuery).usesCameraData
        if let status = scanStatus, needsCameraData || !hasAnyMetadata { return (status, false) }
        return nil
    }

    private var searchHint: (text: String, isWarning: Bool)? {
        Self.hint(forSearch: catalog.searchText, scanStatus: catalog.metadataScanStatusText,
                  hasAnyMetadata: !catalog.metadataByPhotoID.isEmpty,
                  savedQuery: catalog.selectedSmartCollectionQuery)
    }

    private func chip(_ isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.m).fill(isActive ? Theme.selectedFill : Color.clear)
    }

    /// Which row to draw: `.adaptive` lets `ViewThatFits` choose (the app); tests pin one row.
    enum Layout { case adaptive, full, collapsed }
    var layout: Layout = .adaptive

    private typealias L = LibraryFilterBarLayout

    private var visiblePeople: [PersonSummary] {
        catalog.people.filter { !$0.isHidden || $0.id == catalog.personFilterID }
    }

    // MARK: Pop-up bodies (shared by the full row and the Filters menu)

    private func ratingPicker(_ style: some PickerStyle) -> some View {
        Picker("Rating", selection: $catalog.minimumRating) {
            Text("Any Rating").tag(0)
            ForEach(1...5, id: \.self) { stars in
                Text(String(repeating: "★", count: stars) + "+").tag(stars)
            }
        }
        .pickerStyle(style)
        .labelsHidden()
        .accessibilityLabel("Rating")
    }

    private func flagPicker(_ style: some PickerStyle) -> some View {
        Picker("Flag", selection: $catalog.flagFilter) {
            ForEach(LibraryFlagFilter.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(style)
        .labelsHidden()
        .accessibilityLabel("Flag")
    }

    private func labelPicker(_ style: some PickerStyle) -> some View {
        Picker("Label", selection: $catalog.labelFilter) {
            ForEach(LibraryLabelFilter.allCases) { option in
                if let label = option.colorLabel, let swatch = LabelSwatch.image(for: label) {
                    Label { Text(option.label) } icon: { Image(nsImage: swatch) }.tag(option)
                } else {
                    Text(option.label).tag(option)
                }
            }
        }
        .pickerStyle(style)
        .labelsHidden()
        .accessibilityLabel("Label")
    }

    private func keywordPicker(_ style: some PickerStyle) -> some View {
        Picker("Keyword", selection: $catalog.keywordFilterID) {
            Text("All Keywords").tag(Int64?.none)
            let counts = catalog.keywordPhotoCounts
            ForEach(catalog.keywords) { keyword in
                Text("\(keyword.name) (\(counts[keyword.id ?? -1, default: 0]))").tag(keyword.id)
            }
        }
        .pickerStyle(style)
        .labelsHidden()
        .accessibilityLabel("Keyword")
    }

    private func personPicker(_ style: some PickerStyle) -> some View {
        Picker("Person", selection: $catalog.personFilterID) {
            Text("All People").tag(Int64?.none)
            ForEach(visiblePeople) { person in
                Text("\(person.displayName) (\(person.photoCount))").tag(Int64?.some(person.id))
            }
        }
        .pickerStyle(style)
        .labelsHidden()
        .accessibilityLabel("Person")
    }

    // MARK: Pieces

    private func searchField(collapsed: Bool) -> some View {
        TextField("Search name, keyword or iso:>800 camera:d610…", text: $catalog.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: collapsed ? L.searchCollapsedMinWidth : L.searchIdealWidth,
                   idealWidth: collapsed ? nil : L.searchIdealWidth,
                   maxWidth: collapsed ? .infinity : L.searchMaxWidth)
            .accessibilityLabel("Search")
    }

    /// While the search has an unreadable term the glyph turns into the amber triangle (the text itself is in the grid's bottom bar).
    private func helpButton() -> some View {
        let warning = searchHint.flatMap { $0.isWarning ? $0.text : nil }
        return Button { showingSearchHelp.toggle() } label: {
            Image(systemName: warning == nil ? "questionmark.circle" : "exclamationmark.triangle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(warning == nil ? Theme.textSecondary : Theme.warning)
        .frame(width: L.iconSlot)
        .help(warning.map { "\($0). Click for the search syntax." } ?? "Search syntax")
        .accessibilityLabel("Search syntax help")
        .accessibilityValue(warning ?? "")
        .popover(isPresented: $showingSearchHelp, arrowEdge: .bottom) { SearchHelpView() }
    }

    /// Always in the row (invisible and inert while idle), so the bar's width never depends on the filter state.
    private func clearSlot(isActive: Bool) -> some View {
        Button {
            catalog.clearFiltersKeepingSort()
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .frame(width: L.iconSlot)
        .opacity(isActive ? 1 : 0)
        .disabled(!isActive)
        .accessibilityHidden(!isActive)
        .help("Clear filters")
        .accessibilityLabel("Clear filters")
    }

    private func fullRow(_ state: LibraryFilterState) -> some View {
        HStack(spacing: L.spacing) {
            searchField(collapsed: false)
            helpButton()
            Spacer(minLength: 0)
            ratingPicker(.menu).background(chip(state.isRatingActive)).frame(width: L.ratingWidth, alignment: .leading)
            flagPicker(.menu).background(chip(state.isFlagActive)).frame(width: L.flagWidth, alignment: .leading)
            labelPicker(.menu).background(chip(state.isLabelActive)).frame(width: L.labelWidth, alignment: .leading)
            keywordPicker(.menu).background(chip(state.isKeywordActive)).frame(width: L.keywordWidth, alignment: .leading)
            // Only when the catalog has people (the People sheet makes them); a hidden person is left out, unless it is the active filter.
            if !visiblePeople.isEmpty {
                personPicker(.menu).background(chip(state.isPersonActive)).frame(width: L.personWidth, alignment: .leading)
            }
            clearSlot(isActive: state.isActive)
        }
        .padding(.horizontal, L.horizontalPadding)
    }

    private func collapsedRow(_ state: LibraryFilterState) -> some View {
        let count = state.menuFilterCount
        return HStack(spacing: L.spacing) {
            searchField(collapsed: true)
            helpButton()
            Menu {
                Menu("Rating") { ratingPicker(.inline) }
                Menu("Flag") { flagPicker(.inline) }
                Menu("Label") { labelPicker(.inline) }
                Menu("Keyword") { keywordPicker(.inline) }
                if !visiblePeople.isEmpty { Menu("Person") { personPicker(.inline) } }
            } label: {
                Label(L.filtersTitle(count: count), systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.button)
            .buttonStyle(FlatButtonStyle(compact: true))
            .menuIndicator(.visible)
            .fixedSize()
            .background(chip(count > 0))
            .accessibilityLabel("Filters")
            .accessibilityValue(L.filtersAccessibilityValue(count: count))
            clearSlot(isActive: state.isActive)
        }
        .padding(.horizontal, L.horizontalPadding)
    }

    var body: some View {
        let state = catalog.libraryFilterState
        Group {
            switch layout {
            case .full: fullRow(state)
            case .collapsed: collapsedRow(state)
            case .adaptive:
                ViewThatFits(in: .horizontal) {
                    fullRow(state)
                    collapsedRow(state)
                }
            }
        }
        .frame(height: Theme.Metrics.barHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library filters")
    }
}

/// The search syntax popover.
struct SearchHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.px6) {
            Text("Search").font(.headline).foregroundStyle(Theme.textPrimary)
            ForEach(SearchHelp.rows, id: \.field) { row in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(row.example).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 150, alignment: .leading)
                    Text(row.meaning).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(SearchHelp.note).font(.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true).frame(width: 340, alignment: .leading).padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.px14)
        // A system popover is translucent: on a busy grid the grey caption text became hard to read (seen live). A solid panel
        // behind the content, like the app's other overlays.
        .background(Theme.panel)
    }
}
