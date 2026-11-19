import SwiftUI

/// Draws `PhotoActionMenu.entries` as menu rows: the grid cell's context menu and its ellipsis menu (and, later, the selection bar's More
/// menu). One row per entry, a `Divider` between groups, submenus as `Menu`. Keeps the old checkmark + VoiceOver pattern (", current" /
/// ", member") and the red destructive label. The collection submenu's children are the catalog's collections, as before.
struct PhotoActionMenuItems: View {
    let target: PhotoActionTarget
    let context: PhotoActionContext
    let collections: [PhotoCollection]
    let perform: (PhotoActionCommand) -> Void

    var body: some View {
        let groups = PhotoActionMenu.entries(target: target, context: context)
        // Identity from the group's first entry id (unique per group), not its position.
        ForEach(Array(groups.enumerated()), id: \.element[0].id) { index, group in
            if index > 0 { Divider() }
            ForEach(group, id: \.id) { entry in
                row(entry)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: PhotoActionMenu.Entry) -> some View {
        if entry.action == .collectionMenu {
            Menu(entry.title) {
                ForEach(collections) { collection in
                    collectionRow(collection)
                }
            }
            .disabled(!entry.isEnabled)
        } else if !entry.children.isEmpty {
            Menu(entry.title) {
                ForEach(entry.children, id: \.id) { child in PhotoActionLeaf(entry: child, perform: perform) }
            }
            .disabled(!entry.isEnabled)
        } else {
            PhotoActionLeaf(entry: entry, perform: perform)
        }
    }

    private func collectionRow(_ collection: PhotoCollection) -> some View {
        let id = collection.id ?? -1
        let command = PhotoActionMenu.collectionCommand(for: id, target: target)
        // A checkmark only exists for the toggle form (exactly one photo's cell).
        var isMember = false
        if case .toggleCollection = command { isMember = target.cell?.memberships.contains(id) ?? false }
        return Button {
            perform(command)
        } label: {
            HStack {
                Text(collection.name)
                Spacer()
                if isMember { Image(systemName: "checkmark") }
            }
            // The checkmark is glyph-only: fold the state into the label for VoiceOver.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isMember ? "\(collection.name), member" : collection.name)
        }
    }

}

/// One leaf row of a photo-action menu (a button, with the checkmark + VoiceOver pattern for rating / flag / label rows and the red
/// destructive label). Shared by the cell menus (`PhotoActionMenuItems`) and the Photo menu's Rating / Flag / Label submenus.
struct PhotoActionLeaf: View {
    let entry: PhotoActionMenu.Entry
    let perform: (PhotoActionCommand) -> Void

    var body: some View {
        Button(role: entry.isDestructive ? .destructive : nil) {
            if let command = entry.command { perform(command) }
        } label: {
            label
        }
        .disabled(!entry.isEnabled)
    }

    @ViewBuilder
    private var label: some View {
        labelContent(for: entry)
    }

    @ViewBuilder
    private func labelContent(for entry: PhotoActionMenu.Entry) -> some View {
        if entry.isDestructive {
            // `role: .destructive` alone does not render red text on a macOS `Menu` item (seen live on the old cell menu).
            Label {
                Text(entry.title).foregroundStyle(.red)
            } icon: {
                Image(systemName: Self.symbol(for: entry.action) ?? "trash").foregroundStyle(.red)
            }
        } else if isStateRow(entry) {
            HStack {
                Text(entry.title)
                Spacer()
                if entry.isChecked { Image(systemName: "checkmark") }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.isChecked ? "\(entry.title), current" : entry.title)
        } else if let symbol = Self.symbol(for: entry.action) {
            Label(entry.title, systemImage: symbol)
        } else {
            Text(entry.title)
        }
    }

    /// Rating, flag and label rows show the current value with a checkmark.
    private func isStateRow(_ entry: PhotoActionMenu.Entry) -> Bool {
        switch entry.command {
        case .rate, .flag, .label: return true
        default: return false
        }
    }

    private static func symbol(for action: PhotoActionID) -> String? {
        switch action {
        case .makeCover: return "star.square"
        case .removeFromStack: return "rectangle.stack.badge.minus"
        case .createVirtualCopy: return "square.on.square"
        case .locate: return "questionmark.folder"
        case .removeFromLibrary: return "trash"
        default: return nil
        }
    }
}
