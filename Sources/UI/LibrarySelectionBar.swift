import SwiftUI

/// The bar under the Library grid while two or more photos are selected (it replaced the toolbar's "n Selected" menu). The look is
/// `EditorRatingBar`'s: `Theme.panel`, `Theme.Metrics.barHeight`, a top divider. Left to right: the count, Rating / Flag / Label /
/// Add to Collection, Keywords, Export, a More menu with every photo action, and Clear.
///
/// The target is the SELECTION with no cell attached (`PhotoActionTarget.selection`): rating, flag and label write the selected photos
/// the grid shows (the performer's default), and `isOpenPhoto` is set only when the open photo is among them. The grid builds that
/// target once per body (the same one its cell menus use) and passes it in, so the bar does no filtering or sorting of its own.
///
/// Clear is never disabled and never gated on a count (IMPROVEMENTS.md D33): the bar itself is keyed on the RAW `selectedPhotoIDs` (the
/// grid mounts it), so a selection whose ids are all ghosts (photos toggled out of the viewed collection but still selected) can
/// always be cleared. The count label is `target.count`, which is the number of selected photos that are loaded (what the
/// old toolbar label counted).
///
/// A narrow window gets the compact row (icons only, with help text and VoiceOver labels) through `ViewThatFits`.
struct LibrarySelectionBar: View {
    /// The catalog's collections (the Add to Collection menu).
    let collections: [PhotoCollection]
    let context: PhotoActionContext
    /// The selection target, built by the grid.
    let target: PhotoActionTarget
    /// Runs a chosen command (the grid supplies its performer's `perform` with no clicked photo).
    let perform: (PhotoActionCommand) -> Void
    /// Called after any bar action so the grid can take keyboard focus back (Esc and the arrows keep working).
    var onDidAct: () -> Void = {}
    /// `.adaptive` is the real behaviour; a test pins one row to measure it.
    enum Layout { case adaptive, full, compact }
    var layout: Layout = .adaptive

    var body: some View {
        let count = target.count
        Group {
            switch layout {
            case .full:
                row(target: target, count: count, compact: false)
            case .compact:
                row(target: target, count: count, compact: true)
            case .adaptive:
                ViewThatFits(in: .horizontal) {
                    row(target: target, count: count, compact: false)
                    row(target: target, count: count, compact: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.barHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }

    // MARK: Rows

    private func row(target: PhotoActionTarget, count: Int, compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Text("\(count) selected")
                .font(.caption).monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1).fixedSize()
                .accessibilityLabel(count == 1 ? "1 photo selected" : "\(count) photos selected")
            submenu(.ratingMenu, symbol: "star", target: target, compact: compact)
            submenu(.flagMenu, symbol: "flag", target: target, compact: compact)
            submenu(.labelMenu, symbol: "tag", target: target, compact: compact)
            collectionMenu(target: target, compact: compact)
            actionButton(.editKeywords, symbol: "text.badge.plus", target: target, compact: compact)
            actionButton(.export, symbol: "square.and.arrow.up", target: target, compact: compact)
            moreMenu(target: target, compact: compact)
            Spacer(minLength: 8)
            // Never disabled: see the type's comment (D33).
            Button {
                perform(.run(.clearSelection))
                onDidAct()
            } label: {
                chipLabel(PhotoActionMenu.title(.clearSelection), symbol: "xmark.circle", compact: compact)
            }
            .buttonStyle(FlatButtonStyle(compact: true))
            .help("Clear the selection")
            .accessibilityLabel("Clear selection")
        }
    }

    /// Text + icon in the full row, the icon alone in the compact one (the caller adds `.help` and the VoiceOver label).
    @ViewBuilder
    private func chipLabel(_ title: String, symbol: String, compact: Bool) -> some View {
        if compact {
            Image(systemName: symbol)
        } else {
            Label(title, systemImage: symbol).lineLimit(1)
        }
    }

    private func isEnabled(_ action: PhotoActionID, _ target: PhotoActionTarget) -> Bool {
        PhotoActionMenu.isEnabled(action, target: target, context: context)
    }

    private func actionButton(_ action: PhotoActionID, symbol: String, target: PhotoActionTarget, compact: Bool) -> some View {
        let title = PhotoActionMenu.title(action)
        return Button {
            perform(.run(action))
            onDidAct()
        } label: {
            chipLabel(title, symbol: symbol, compact: compact)
        }
        .buttonStyle(FlatButtonStyle(compact: true))
        .disabled(!isEnabled(action, target))
        .help(title)
        .accessibilityLabel(title)
    }

    /// Rating / Flag / Label: the model's own children, with the current value checked (the context menu's pattern).
    private func submenu(_ action: PhotoActionID, symbol: String, target: PhotoActionTarget, compact: Bool) -> some View {
        let title = PhotoActionMenu.title(action)
        let entry = PhotoActionMenu.entry(for: action, target: target, context: context)
        return Menu {
            ForEach(entry?.children ?? [], id: \.id) { child in
                Button {
                    if let command = child.command { perform(command) }
                    onDidAct()
                } label: {
                    HStack {
                        Text(child.title)
                        Spacer()
                        if child.isChecked { Image(systemName: "checkmark") }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(child.isChecked ? "\(child.title), current" : child.title)
                }
            }
        } label: {
            menuLabel(title, symbol: symbol, compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(FlatButtonStyle(compact: true))
        .menuIndicator(.hidden)
        .disabled(!(entry?.isEnabled ?? false))
        .help(title)
        .accessibilityLabel(title)
    }

    private func collectionMenu(target: PhotoActionTarget, compact: Bool) -> some View {
        let title = PhotoActionMenu.title(.collectionMenu)
        return Menu {
            ForEach(collections) { collection in
                let id = collection.id ?? -1
                Button(collection.name) {
                    perform(PhotoActionMenu.collectionCommand(for: id, target: target))
                    onDidAct()
                }
            }
        } label: {
            menuLabel(title, symbol: "rectangle.stack.badge.plus", compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(FlatButtonStyle(compact: true))
        .menuIndicator(.hidden)
        .disabled(!isEnabled(.collectionMenu, target))
        .help(title)
        .accessibilityLabel(title)
    }

    private func moreMenu(target: PhotoActionTarget, compact: Bool) -> some View {
        Menu {
            PhotoActionMenuItems(target: target, context: context, collections: collections) { command in
                perform(command)
                onDidAct()
            }
        } label: {
            menuLabel("More", symbol: "ellipsis.circle", compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(FlatButtonStyle(compact: true))
        .menuIndicator(.hidden)
        .help("More photo actions")
        .accessibilityLabel("More")
    }

    private func menuLabel(_ title: String, symbol: String, compact: Bool) -> some View {
        chipLabel(title, symbol: symbol, compact: compact)
    }
}
