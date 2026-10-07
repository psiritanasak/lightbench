import SwiftUI

/// The Adjust tab's "Style" section: preset chips (our own two families), a square Tone/Color pad, a Strength slider, a
/// text readout and Reset. Everything writes the four `EditState.style*` fields — never the user's own sliders — so it is
/// non-destructive and undoable; a preset click is its own labelled History step (`ImageDocumentModel.selectStyle`).
struct StyleSectionView: View {
    @ObservedObject var document: ImageDocumentModel

    private var state: EditState { document.editState }

    private var toneBinding: Binding<Double> {
        Binding(get: { state.styleTone }, set: { document.editState.styleTone = $0.isFinite ? min(max($0, -1), 1) : 0 })
    }
    private var colorBinding: Binding<Double> {
        Binding(get: { state.styleColor }, set: { document.editState.styleColor = $0.isFinite ? min(max($0, -1), 1) : 0 })
    }
    private var strengthBinding: Binding<Double> {
        Binding(get: { state.styleStrength }, set: { document.editState.styleStrength = $0.isFinite ? min(max($0, 0), 1) : 1 })
    }

    private var isAtIdentity: Bool {
        state.styleID.isEmpty && state.styleTone == 0 && state.styleColor == 0 && state.styleStrength == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) { chip(id: "", name: "None") }
            ForEach(StylePreset.Family.allCases, id: \.self) { family in
                presetGrid(title: family.title, presets: StyleLibrary.presets(in: family))
            }
            if !state.styleID.isEmpty, StyleLibrary.preset(for: state.styleID) == nil {
                Text("Style not found — this photo uses a style from a newer version. It is shown without it.")
                    .font(.caption).foregroundStyle(.orange)
            }
            StylePadView(tone: toneBinding, color: colorBinding)
            Text(readout).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)
            EditSliderRow(label: "Strength", value: strengthBinding, range: 0...1, identity: 1, displayMultiplier: 100) {
                String(format: "%.0f%%", $0 * 100)
            }
            // Nothing to scale (no preset, pad centred): the slider would only write an invisible edit.
            .disabled(StyleMath.isIdentity(id: state.styleID, tone: state.styleTone, color: state.styleColor))
            Text("Color is mostly Vibrance (designed to spare skin tones) plus some Saturation; there is no skin masking yet.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Reset Style") { document.resetStyle() }
                .disabled(isAtIdentity)
                .frame(maxWidth: .infinity)
        }
    }

    private var readout: String {
        String(format: "Tone %+.2f   Color %+.2f", state.styleTone, state.styleColor)
    }

    private static let columns = [GridItem(.adaptive(minimum: 68), spacing: 6)]

    private func presetGrid(title: String, presets: [StylePreset]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                ForEach(presets) { preset in chip(id: preset.id, name: preset.name) }
            }
        }
    }

    private func chip(id: String, name: String) -> some View {
        let selected = state.styleID == id
        return Button { document.selectStyle(id) } label: {
            Text(name).font(.callout).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
        .fontWeight(selected ? .semibold : .regular)
        .accessibilityLabel(id.isEmpty ? "No style" : "Style \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The square Tone (vertical) / Color (horizontal) pad. A fixed frame (not negotiated) so the sidebar cannot resize
/// mid-drag — the `ColorGradingWheelView` lesson. Unlike the wheel it is reachable without a pointer: Tone/Color have
/// VoiceOver adjustable/named actions.
struct StylePadView: View {
    @Binding var tone: Double
    @Binding var color: Double

    private static let side: CGFloat = 190
    private static let step = 0.1

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                Rectangle().fill(LinearGradient(colors: [.white.opacity(0.14), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: CGPoint(x: rect.midX, y: 0)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    path.move(to: CGPoint(x: 0, y: rect.midY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                }
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                    .position(StylePadGeometry.screenPoint(tone: tone, color: color, in: rect))
                    .allowsHitTesting(false)
                Color.clear.contentShape(Rectangle()).gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
                        let v = StylePadGeometry.values(at: value.location, in: rect)
                        tone = v.tone
                        color = v.color
                    }
                )
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .overlay(alignment: .top) { axisLabel("Tone +").padding(.top, 2) }
        .overlay(alignment: .bottom) { axisLabel("Tone −").padding(.bottom, 2) }
        .overlay(alignment: .leading) { axisLabel("Color −").padding(.leading, 3) }
        .overlay(alignment: .trailing) { axisLabel("Color +").padding(.trailing, 3) }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Style pad")
        .accessibilityValue(String(format: "Tone %.2f, Color %.2f", tone, color))
        .accessibilityAdjustableAction { direction in
            tone = StylePadGeometry.stepped(tone, by: direction == .increment ? Self.step : -Self.step)
        }
        .accessibilityAction(named: "Increase Color") { color = StylePadGeometry.stepped(color, by: Self.step) }
        .accessibilityAction(named: "Decrease Color") { color = StylePadGeometry.stepped(color, by: -Self.step) }
        .accessibilityAction(named: "Reset Pad") { tone = 0; color = 0 }
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)).allowsHitTesting(false)
    }
}
