import SwiftUI

/// The vertical icon rail at the Editor's right edge. Top group: one entry per `EditorTab.railTabs` (icon over a small caption),
/// the selected one tinted — it only switches `selectedTab`; every rule that follows a tab change (Compare/zoom, disarming point
/// modes) stays in `ContentView`'s `.onChange(of: selectedTab)`. Optional second group (`EditorRailActions`: Undo, Redo, Revert,
/// History, Compare, Filmstrip, Enhance) under a divider. Both groups scroll together so a short window scrolls instead of clipping.
/// The rail's fixed width, outside the generic view so it can be named without type arguments.
enum EditorToolRailMetrics {
    static let width: CGFloat = 56
}

struct EditorToolRail<Actions: View>: View {
    @Binding var selectedTab: EditorTab
    let actions: Actions

    init(selectedTab: Binding<EditorTab>, @ViewBuilder actions: () -> Actions) {
        _selectedTab = selectedTab
        self.actions = actions()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(EditorTab.railTabs, id: \.self) { tab in
                    let isSelected = tab == selectedTab
                    Button {
                        selectedTab = tab
                    } label: {
                        RailEntryLabel(title: tab.railTitle, symbol: tab.railSymbol, isOn: isSelected)
                    }
                    .buttonStyle(.plain)
                    .help(tab.railTitle)
                    .accessibilityLabel(tab.railTitle)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
                if Actions.self != EmptyView.self {
                    Divider().padding(.horizontal, 10).padding(.vertical, 4)
                    actions
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .frame(width: EditorToolRailMetrics.width)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.12))
        .overlay(alignment: .leading) { Divider() }
    }
}

extension EditorToolRail where Actions == EmptyView {
    /// The tabs-only rail (what the rail was before it grew an actions group).
    init(selectedTab: Binding<EditorTab>) {
        self.init(selectedTab: selectedTab) { EmptyView() }
    }
}
