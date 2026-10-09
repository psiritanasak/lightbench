import SwiftUI

/// The full-window cull view: one big photo, a progress bar on top, the rating / flag / label controls below. Keys do the work (see
/// `CullKeyAction`); the controls are for the mouse. It has its own keyboard focus; the Editor's key handlers are not mounted while it
/// is up.
struct CullView: View {
    @ObservedObject var model: CullModel
    @ObservedObject var catalog: CatalogModel
    let onExit: () -> Void
    let onOpenInEditor: (Photo) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        // One dictionary of the live rows per update (not one per access).
        let rows = model.environment.rows()
        let photo = model.current(in: rows)
        let counts = model.counts(in: rows)
        VStack(spacing: 0) {
            topBar(counts: counts)
            ZStack {
                Color.black
                photoLayer(photo)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(photoDescription(photo))
                    .accessibilityAction(named: "Next photo") { model.handle(.next) }
                    .accessibilityAction(named: "Previous photo") { model.handle(.previous) }
                if let note = model.note {
                    Text(note)
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .solidPanel(cornerRadius: 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 24)
                        .allowsHitTesting(false)
                }
            }
            .overlay { SizeReporter { size in model.setViewSize(longEdge: Double(max(size.width, size.height)), scale: scale) } }
            bottomBar(photo)
        }
        .background(Theme.panel)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
        .onChange(of: model.note) { _, note in
            if let note { AccessibilityNotification.Announcement(note).post() }
        }
        .onAppear { isFocused = true }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
    }

    private var scale: Double { Double(NSScreen.main?.backingScaleFactor ?? 2) }

    // MARK: Pieces

    private func topBar(counts: CullSession.Counts) -> some View {
        HStack(spacing: 14) {
            Button { onExit() } label: { Label("Exit", systemImage: "xmark") }
                .buttonStyle(.flat)
                .help("Leave culling (Esc)")
            Text(model.session?.positionText ?? "").monospacedDigit()
            Text("Unflagged \(counts.unflagged) · Picked \(counts.picked) · Rejected \(counts.rejected)")
                .font(.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
            Spacer()
            Toggle("Advance after flag", isOn: Binding(get: { model.autoAdvance }, set: { model.autoAdvance = $0 }))
                .help("After Pick / Reject / Unflag, show the next photo")
            Toggle("Unflagged only", isOn: Binding(get: { model.onlyUnflagged }, set: { model.setOnlyUnflagged($0) }))
                .help("Cull only photos that have no flag yet")
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.barHeight + 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func photoLayer(_ photo: Photo?) -> some View {
        if let image = model.image {
            // While the next photo loads the OLD picture stays up, dimmed with a spinner, and photo keys are refused (`CullModel.imagePhotoID`).
            let ready = model.showsCurrentPhoto
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(!ready ? 0.3 : (photo?.flagStatus == .rejected ? 0.45 : 1))
                .overlay(alignment: .topLeading) { if ready { flagBadge(photo?.flagStatus ?? .none) } }
                .overlay(alignment: .bottomTrailing) {
                    if model.isPlaceholder || !ready { ProgressView().controlSize(.small).padding(10) }
                }
        } else if model.decodeFailed {
            Text("This photo can't be shown").foregroundStyle(Theme.textSecondary)
        } else {
            ProgressView().controlSize(.large)
        }
    }

    /// "IMG_0042.jpg, picked, 3 stars" for VoiceOver.
    private func photoDescription(_ photo: Photo?) -> String {
        guard let photo else { return "Photo" }
        var parts = [photo.filename]
        if photo.flagStatus != .none { parts.append(photo.flagStatus.accessibilityValue.lowercased()) }
        if photo.rating > 0 { parts.append("\(photo.rating) star\(photo.rating == 1 ? "" : "s")") }
        if photo.colorLabel != .none { parts.append(photo.colorLabel.accessibilityName) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func flagBadge(_ status: FlagStatus) -> some View {
        if status != .none {
            Image(systemName: status.symbolName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(status.tint)
                .padding(14)
                .accessibilityLabel(status.accessibilityValue)
        }
    }

    private func bottomBar(_ photo: Photo?) -> some View {
        HStack(spacing: 14) {
            StarRatingRow(rating: photo?.rating ?? 0) { model.handle(.command(.rating($0))) }
            flagButton(.picked, current: photo?.flagStatus ?? .none)
            flagButton(.rejected, current: photo?.flagStatus ?? .none)
            labelDots(current: photo?.colorLabel ?? .none)
            Spacer()
            Text("← → move · P pick · X reject · U clear · 0–5 rate · 6–9 label · ⌘Z undo · Return opens in Editor")
                .font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.barHeight)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider() }
    }

    private func flagButton(_ target: FlagStatus, current: FlagStatus) -> some View {
        let isOn = current == target
        let name = target == .picked ? "Pick" : "Reject"
        return Button {
            model.handle(.command(.flag(target)))
        } label: {
            Image(systemName: isOn ? target.symbolName : (target == .picked ? "flag" : "xmark.circle"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? target.tint : Theme.textSecondary)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func labelDots(current: ColorLabel) -> some View {
        HStack(spacing: 5) {
            ForEach(ColorLabel.menuOrder.filter { $0 != .none }, id: \.self) { label in
                Button { model.handle(.command(.label(label))) } label: {
                    Circle().fill(label.color).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.primary.opacity(current == label ? 0.9 : 0.15), lineWidth: current == label ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label.accessibilityName)
                .accessibilityAddTraits(current == label ? [.isSelected] : [])
            }
        }
    }

    // MARK: Keys

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        let key: CullKey
        switch press.key {
        case .leftArrow: key = .leftArrow
        case .rightArrow: key = .rightArrow
        case .space: key = .space
        case .escape: key = .escape
        case .return: key = .returnKey
        default:
            guard let character = press.characters.first else { return .ignored }
            key = .character(character)
        }
        guard let action = CullKeyAction.action(for: key) else { return .ignored }
        // Holding a key repeats it: fine for moving, but a held P / X / U (or a rating) must not flag a RUN of photos, and a held
        // Escape / Return must not fire twice.
        if press.phase == .repeat {
            switch action {
            case .previous, .next: break
            default: return .handled
            }
        }
        switch model.handle(action) {
        case .done: break
        case .exit: onExit()
        case .openInEditor(let photo): onOpenInEditor(photo)
        }
        return .handled
    }
}

/// Reports the size of the view it overlays (the photo area) so previews can be decoded at the screen's resolution.
private struct SizeReporter: View {
    let onSize: (CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onSize(proxy.size) }
                .onChange(of: proxy.size) { _, size in onSize(size) }
        }
        .allowsHitTesting(false)
    }
}
