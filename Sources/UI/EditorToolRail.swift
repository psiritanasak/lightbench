import SwiftUI

/// The vertical icon rail at the Editor's right edge: one entry per `EditorTab.railTabs` (icon over a small caption), the selected
/// one tinted. It replaces the old segmented tab bar above the photo and only switches `selectedTab` — every rule that follows a
/// tab change (Compare/zoom, disarming point modes) stays in `ContentView`'s `.onChange(of: selectedTab)`.
struct EditorToolRail: View {
    @Binding var selectedTab: EditorTab

    static let width: CGFloat = 56

    var body: some View {
        VStack(spacing: 6) {
            ForEach(EditorTab.railTabs, id: \.self) { tab in
                let isSelected = tab == selectedTab
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.railSymbol).font(.system(size: 17))
                        Text(tab.railTitle).font(.system(size: 10))
                    }
                    .frame(width: Self.width - 8, height: 48)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(tab.railTitle)
                .accessibilityLabel(tab.railTitle)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.12))
        .overlay(alignment: .leading) { Divider() }
    }
}
