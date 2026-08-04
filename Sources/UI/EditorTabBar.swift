import SwiftUI

/// A segmented-pill tab bar matching Apple Photos' own tool switcher —
/// rounded capsule background, the selected tab gets a lighter pill behind
/// it. Placed above the image pane (not the window toolbar), so it stays
/// visually anchored to the editing area like the reference.
struct EditorTabBar: View {
    @Binding var selectedTab: EditorTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.label)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(tab == selectedTab ? Color(white: 0.32) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color(white: 0.16)))
        .padding(.vertical, 8)
    }
}
