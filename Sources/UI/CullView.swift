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
                content(photo, rows: rows)
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
            .overlay { SizeReporter { size in model.setViewArea(width: Double(size.width), height: Double(size.height), scale: scale) } }
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
            Picker("View", selection: Binding(get: { model.session?.mode ?? .loupe }, set: { model.setMode($0) })) {
                Text("Loupe").tag(CullViewMode.loupe)
                Text("Compare").tag(CullViewMode.compare)
                Text("Survey").tag(CullViewMode.survey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .focusable(false) // a focused segmented control would take ← / → for itself instead of moving through the photos
            .frame(width: 210)
            .help("Loupe · Compare (C) · Survey (N)")
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

    /// The photo area for the current mode: the loupe's one big photo, Compare's select + candidate, or the survey grid.
    @ViewBuilder
    private func content(_ photo: Photo?, rows: [Int64: Photo]) -> some View {
        switch model.session?.mode ?? .loupe {
        case .loupe: photoLayer(photo)
        case .compare:
            HStack(spacing: 2) {
                if let id = model.session?.selectID { cell(id: id, rows: rows, caption: "Select") }
                if let id = model.session?.currentID { cell(id: id, rows: rows, caption: "Candidate") }
            }
        case .survey:
            surveyGrid(rows: rows)
        }
    }

    private func surveyGrid(rows: [Int64: Photo]) -> some View {
        let ids = model.session?.surveyIDs ?? []
        return GeometryReader { proxy in
            let layout = CullLayout.grid(count: ids.count, area: proxy.size)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: layout.columns)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(ids, id: \.self) { id in
                    cell(id: id, rows: rows, caption: nil)
                        .frame(height: max(40, (proxy.size.height - CGFloat(layout.rows - 1) * 2) / CGFloat(layout.rows)))
                }
            }
        }
    }

    /// One Compare / Survey cell: the photo fitted into the cell, its flag, rating and name, and a ring on the one the keys act on.
    private func cell(id: Int64, rows: [Int64: Photo], caption: String?) -> some View {
        let photo = rows[id]
        let focused = id == model.session?.currentID
        let slot = model.slots[id]
        return ZStack {
            Color.black
            if let image = slot?.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(photo?.flagStatus == .rejected ? 0.45 : 1)
            } else if slot?.failed == true {
                Text("Can't be shown").font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .overlay(alignment: .topLeading) { flagBadge(photo?.flagStatus ?? .none).scaleEffect(0.6, anchor: .topLeading) }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if let caption { Text(caption).font(.caption.weight(.semibold)) }
                Text(photo?.filename ?? "").font(.caption).lineLimit(1)
                if let rating = photo?.rating, rating > 0 { Text(String(repeating: "★", count: rating)).font(.caption) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.black.opacity(0.55))
            .foregroundStyle(.white)
            .padding(6)
        }
        .overlay(alignment: .bottomTrailing) { if slot?.isPlaceholder == true { ProgressView().controlSize(.small).padding(8) } }
        .overlay { if focused { Rectangle().stroke(Theme.selectedOutline, lineWidth: 3) } }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { model.focus(on: id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photoDescription(photo) + (caption.map { ", \($0)" } ?? "") + (focused ? ", focused" : ""))
        .accessibilityAddTraits(focused ? [.isSelected] : [])
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
            Text(hint)
                .font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.barHeight)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider() }
    }

    private var hint: String {
        switch model.session?.mode ?? .loupe {
        case .loupe: return "← → move · P pick · X reject · U clear · 0–5 rate · 6–9 label · C compare · N survey · ⌘Z undo · Return opens in Editor"
        case .compare: return "← → candidate · ↑ swap · ↓ make select · P X U 0–5 6–9 act on the candidate · C / Esc back · ⌘Z undo"
        case .survey: return "← → focus · / remove from page · P X U 0–5 6–9 act on the focused photo · N / Esc back · ⌘Z undo"
        }
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
        case .upArrow: key = .upArrow
        case .downArrow: key = .downArrow
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
