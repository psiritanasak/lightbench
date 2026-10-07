import SwiftUI

/// The editor toolbar's History popover: every committed edit of the open photo, newest first, as a scrubbable list. Tapping a
/// row jumps the photo (and its saved sidecar) to that state through `ImageDocumentModel.jumpToHistory(id:)` and the popover
/// STAYS OPEN so the user can scrub back and forth. The current row is scrolled into view when the popover opens and whenever it
/// changes. Rows come from the pure `HistoryRow.rows`, which owns the ordering and the VoiceOver strings.
///
/// A popover has no scrolling parent, so a plain bounded `ScrollView` is fine here — the "no nested ScrollView" rule the
/// Adjust sidebar's old History section followed applies only inside that sidebar.
struct HistoryPopoverView: View {
    @ObservedObject var document: ImageDocumentModel

    private static let width: CGFloat = 300
    private static let maxHeight: CGFloat = 420
    private static let rowHeight: CGFloat = 28

    var body: some View {
        let rows = HistoryRow.rows(entries: document.historyEntries, currentIndex: document.currentHistoryIndex)
        VStack(alignment: .leading, spacing: 0) {
            Text("History")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowButton(row).id(row.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(height: min(CGFloat(rows.count) * Self.rowHeight + 8, Self.maxHeight))
                // One run-loop turn later on appear: a `LazyVStack` has not laid its rows out yet when `onAppear` fires, and
                // `scrollTo` before layout does nothing (unverified live — see the History entry in the docs).
                .onAppear { DispatchQueue.main.async { scrollToCurrent(rows, proxy) } }
                .onChange(of: document.currentHistoryIndex) { _, _ in scrollToCurrent(rows, proxy) }
            }
        }
        .frame(width: Self.width)
    }

    private func scrollToCurrent(_ rows: [HistoryRow], _ proxy: ScrollViewProxy) {
        guard let current = rows.first(where: \.isCurrent) else { return }
        proxy.scrollTo(current.id, anchor: .center)
    }

    private func rowButton(_ row: HistoryRow) -> some View {
        Button {
            document.jumpToHistory(id: row.id)
        } label: {
            HStack {
                Text(row.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fontWeight(row.isCurrent ? .semibold : .regular)
                    .foregroundStyle(row.position == .undone ? .secondary : .primary)
                Spacer()
                if row.isCurrent { Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(row.isCurrent ? Color.accentColor.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityText)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
    }
}
