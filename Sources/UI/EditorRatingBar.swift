import SwiftUI

/// The compact row under the Editor's photo: stars, Pick / Reject, colour label, and Copy Settings. Same controls, symbols and
/// accessibility text as the Library grid's cells (`StarRatingRow`, `FlagStatus`, `ColorLabel` presentation). Without a catalog row
/// for the open photo (opened with File > Open and never imported) the rating controls are disabled and say why; Copy Settings
/// does not need the catalog.
struct EditorRatingBar: View {
    @ObservedObject var meta: EditorPhotoMeta
    let canCopy: Bool
    let onCopy: () -> Void

    var body: some View {
        let photo = meta.photo
        HStack(spacing: 14) {
            StarRatingRow(rating: photo?.rating ?? 0) { meta.setRating($0) }
            flagButton(.picked, current: photo?.flagStatus ?? .none)
            flagButton(.rejected, current: photo?.flagStatus ?? .none)
            labelDots(current: photo?.colorLabel ?? .none)
            if photo == nil {
                Text("Not in your Library").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button(action: onCopy) { Label("Copy Settings", systemImage: "doc.on.doc").lineLimit(1) }
                .buttonStyle(.borderless)
                // Same size as the bar's other text ("Not in your Library"); the default control font was larger and wrapped.
                .font(.caption)
                // White (primary) text, not the accent blue a borderless button takes by default.
                .foregroundStyle(canCopy ? Color.primary : Theme.textSecondary)
                .disabled(!canCopy)
                .help("Copy this photo's edit settings (⇧⌘C)")
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.barHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider() }
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
