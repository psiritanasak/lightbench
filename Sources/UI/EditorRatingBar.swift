import SwiftUI

/// The compact row under the Editor's photo: stars, Pick / Reject, colour label, Info and Copy Settings. Same controls, symbols and
/// accessibility text as the Library grid's cells (`StarRatingRow`, `FlagStatus`, `ColorLabel` presentation). Without a catalog row
/// for the open photo (opened with File > Open and never imported) the rating controls are disabled and say why; Copy Settings
/// does not need the catalog.
struct EditorRatingBar: View {
    @ObservedObject var meta: EditorPhotoMeta
    let canCopy: Bool
    let onCopy: () -> Void
    /// The Info popover's state and its button action (⌘I does the same). Without a model there is no Info button.
    var info: EditorInfoModel?
    var onInfo: () -> Void = {}
    /// The "Edits not saved" chip (nil = edits are reaching disk) and what its button does.
    var saveStatus: SidecarSaveStatusPresentation?
    var onSaveAction: (SidecarSaveStatusPresentation.Action) -> Void = { _ in }

    var body: some View {
        let photo = meta.photo
        HStack(spacing: 14) {
            StarRatingRow(rating: photo?.rating ?? 0) { meta.setRating($0) }
            flagButton(.picked, current: photo?.flagStatus ?? .none)
            flagButton(.rejected, current: photo?.flagStatus ?? .none)
            labelDots(current: photo?.colorLabel ?? .none)
            if let saveStatus { saveStatusChip(saveStatus) }
            if photo == nil {
                Text("Not in your Library").font(.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if let info { infoButton(info) }
            Button(action: onCopy) { Label("Copy Settings", systemImage: "doc.on.doc").lineLimit(1) }
                .buttonStyle(.borderless)
                // Same size as the bar's other text ("Not in your Library"); the default control font was larger and wrapped.
                .font(.caption)
                // White (primary) text, not the accent blue a borderless button takes by default.
                .foregroundStyle(canCopy ? Color.primary : Theme.textSecondary)
                .fixedSize()
                .disabled(!canCopy)
                .help("Copy this photo's edit settings (⇧⌘C)")
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.barHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider() }
    }

    /// Amber warning + one action: the edits on screen are not being written to the photo's edit file. Shrinks in steps when the bar
    /// is tight (`ViewThatFits`): triangle + caption + action button, then triangle + action button, then the triangle alone (itself
    /// the action button). What is actually claimed is render-tested at the Editor pane's 480 pt minimum, with the Info button.
    private func saveStatusChip(_ status: SidecarSaveStatusPresentation) -> some View {
        let warning = Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        let button = Button(status.actionTitle) { onSaveAction(status.action) }
            .buttonStyle(FlatButtonStyle(compact: true))
            .lineLimit(1).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                warning
                Text(status.title).font(.caption).foregroundStyle(Theme.warning).lineLimit(1).fixedSize()
                button
            }
            HStack(spacing: 6) { warning; button }
            Button { onSaveAction(status.action) } label: { warning }.buttonStyle(.plain)
                .accessibilityLabel(status.actionTitle)
                .help("\(status.help) Click to \(status.actionTitle).")
        }
        .help(status.help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.title). \(status.help)")
    }

    /// "Info": the title / caption / creator / copyright popover for the open photo. Disabled (with the reason) when the photo has no
    /// catalog row, since Info is catalog data; an open popover stays closable.
    private func infoButton(_ info: EditorInfoModel) -> some View {
        let enabled = meta.photo != nil || info.isOpen
        return Button(action: onInfo) { Label("Info", systemImage: "info.circle").lineLimit(1) }
            .buttonStyle(.borderless)
            .fixedSize()
            .font(.caption)
            .foregroundStyle(enabled ? Color.primary : Theme.textSecondary)
            .disabled(!enabled)
            .help(meta.photo == nil && !info.isOpen ? "Not in your Library" : "Edit this photo's title, caption, creator and copyright (⌘I)")
            .popover(isPresented: Binding(get: { info.isOpen }, set: { if !$0 { info.commit() } }), arrowEdge: .top) {
                EditorInfoPopover(model: info)
            }
    }

    /// Pick or Reject: clicking the photo's current state clears it back to unflagged.
    private func flagButton(_ target: FlagStatus, current: FlagStatus) -> some View {
        let isOn = current == target
        let name = target == .picked ? "Pick" : "Reject"
        return Button {
            meta.setFlag(isOn ? FlagStatus.none : target)
        } label: {
            Image(systemName: target == .picked ? (isOn ? "flag.fill" : "flag") : (isOn ? "xmark.circle.fill" : "xmark.circle"))
                .foregroundStyle(isOn ? target.tint : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(meta.photo == nil)
        .help(target == .picked ? "Pick (P)" : "Reject (X)")
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Six label dots; clicking the photo's current label clears it.
    private func labelDots(current: ColorLabel) -> some View {
        HStack(spacing: 5) {
            ForEach(ColorLabel.menuOrder.filter { $0 != .none }, id: \.self) { label in
                let isOn = current == label
                Button {
                    meta.setLabel(current.toggled(to: label))
                } label: {
                    Circle().fill(label.color).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.primary.opacity(isOn ? 0.9 : 0.15), lineWidth: isOn ? 2 : 1))
                }
                .buttonStyle(.plain)
                .disabled(meta.photo == nil)
                .accessibilityLabel(label.accessibilityName)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
