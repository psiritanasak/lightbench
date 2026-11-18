import SwiftUI

/// Pure value↔pixel mapping for `ThinSlider`, kept SwiftUI-independent
/// (same pattern as `CropAspectMath`) so the one place an off-by-a-
/// thumb-radius bug could hide is unit-tested, not eyeballed.
enum ThinSliderGeometry {
    static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    static func value(atFraction fraction: Double, in range: ClosedRange<Double>) -> Double {
        let f = fraction.clamped(to: 0...1)
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    /// The thumb's CENTER x for a given fraction, inset by half the
    /// thumb's own horizontal extent so it never overhangs either end of
    /// the track.
    static func thumbCenterX(fraction: Double, trackWidth: Double, thumbWidth: Double) -> Double {
        let usableSpan = max(trackWidth - thumbWidth, 0)
        return thumbWidth / 2 + fraction.clamped(to: 0...1) * usableSpan
    }

    /// Inverse of `thumbCenterX`: a drag x (in track-local coordinates)
    /// back to a clamped 0...1 fraction.
    static func fraction(atX x: Double, trackWidth: Double, thumbWidth: Double) -> Double {
        let usableSpan = max(trackWidth - thumbWidth, 0)
        guard usableSpan > 0 else { return 0 }
        return ((x - thumbWidth / 2) / usableSpan).clamped(to: 0...1)
    }

    /// The step size for one VoiceOver increment/decrement — 1/20th of the
    /// range. Shared by `incremented`/`decremented` below purely so the
    /// `/20` constant isn't duplicated between them.
    private static func step(in range: ClosedRange<Double>) -> Double {
        (range.upperBound - range.lowerBound) / 20
    }

    /// D6 (IMPROVEMENTS.md): one VoiceOver increment, clamped to `range` —
    /// matches what `ThinSlider`'s `accessibilityAdjustableAction` used
    /// inline before this was extracted so it could be unit-tested and
    /// reused by `CompareDividerOverlay`'s own adjustable action.
    static func incremented(_ value: Double, in range: ClosedRange<Double>) -> Double {
        Swift.min(value + step(in: range), range.upperBound)
    }

    /// One VoiceOver decrement, clamped to `range`.
    static func decremented(_ value: Double, in range: ClosedRange<Double>) -> Double {
        Swift.max(value - step(in: range), range.lowerBound)
    }

    /// A keyboard action on a focused `ThinSlider`.
    enum Key { case decrease, increase, minimum, maximum }

    /// What a key does to `value`: arrows move one step (the same 1/20th VoiceOver uses), `coarse` (Shift) moves four steps, `fine`
    /// (Option) a quarter of that (both together: one step), Home / End jump to the ends (and ignore both). Always clamped to `range`; a zero-width range stays put.
    static func keyed(_ value: Double, key: Key, coarse: Bool, fine: Bool = false, in range: ClosedRange<Double>) -> Double {
        let amount = step(in: range) * (coarse ? 4 : 1) / (fine ? ThinSliderDrag.fineDivisor : 1)
        let current = value.clamped(to: range)
        switch key {
        case .decrease: return Swift.max(current - amount, range.lowerBound)
        case .increase: return Swift.min(current + amount, range.upperBound)
        case .minimum: return range.lowerBound
        case .maximum: return range.upperBound
        }
    }
}

/// The pure maths of one press-and-drag on a `ThinSlider`, SwiftUI-free so it is unit-tested. A slider that can reset (it has a
/// double-click handler) writes nothing until the pointer has moved `moveThreshold`, so the first click of a double-click never moves
/// the thumb; a slider that cannot reset writes the pointer's value on press, exactly as before. Holding Option makes the drag
/// RELATIVE and `fineDivisor` times slower, re-anchored at the last event so pressing or releasing Option mid-drag never jumps.
struct ThinSliderDrag: Equatable {
    /// Option-drag and Option-arrow speed: a quarter.
    static let fineDivisor: Double = 4
    /// Horizontal points a press on a resettable slider must move before it writes, so a click alone (the first half of a
    /// double-click) never moves the thumb. Picked by eye, a guess: not measured against real hand jitter.
    static let moveThreshold: Double = 3

    struct Track: Equatable {
        var width: Double
        var thumbWidth: Double
        var range: ClosedRange<Double>

        /// Today's mapping: the value under a pointer at `x`.
        func absolute(atX x: Double) -> Double {
            let f = ThinSliderGeometry.fraction(atX: x, trackWidth: width, thumbWidth: thumbWidth)
            return ThinSliderGeometry.value(atFraction: f, in: range)
        }
    }

    enum Start: Equatable { case none, write(Double), reset }

    enum Mode: Equatable {
        /// The press was a double-click: everything after it is ignored.
        case consumed
        /// Resettable, no movement yet.
        case pending(pressX: Double)
        /// `value = value(atX:)`, the long-standing tracking.
        case absolute
        case relative(anchorX: Double, anchorValue: Double, fine: Bool)
    }

    private(set) var mode: Mode
    private(set) var lastX: Double
    private(set) var lastValue: Double

    static func begin(
        x: Double, value: Double, clickCount: Int, optionHeld: Bool, canReset: Bool, track: Track
    ) -> (ThinSliderDrag, Start) {
        if canReset && clickCount >= 2 {
            return (ThinSliderDrag(mode: .consumed, lastX: x, lastValue: value), .reset)
        }
        if optionHeld {
            let mode = Mode.relative(anchorX: x, anchorValue: value, fine: true)
            return (ThinSliderDrag(mode: mode, lastX: x, lastValue: value), .none)
        }
        if canReset {
            return (ThinSliderDrag(mode: .pending(pressX: x), lastX: x, lastValue: value), .none)
        }
        let written = track.absolute(atX: x)
        return (ThinSliderDrag(mode: .absolute, lastX: x, lastValue: written), .write(written))
    }

    /// The value to write for a pointer at `x`, or nil to write nothing (no movement yet, a double-click, or an unchanged value).
    mutating func move(toX x: Double, optionHeld: Bool, track: Track) -> Double? {
        var result: Double?
        switch mode {
        case .consumed:
            result = nil
        case .pending(let pressX):
            if optionHeld {
                mode = .relative(anchorX: lastX, anchorValue: lastValue, fine: true)
                result = relativeValue(atX: x, track: track)
            } else if abs(x - pressX) < Self.moveThreshold {
                result = nil
            } else {
                mode = .absolute
                result = track.absolute(atX: x)
            }
        case .absolute:
            if optionHeld {
                mode = .relative(anchorX: lastX, anchorValue: lastValue, fine: true)
                result = relativeValue(atX: x, track: track)
            } else {
                result = track.absolute(atX: x)
            }
        case .relative(_, _, let fine):
            if optionHeld != fine {
                mode = .relative(anchorX: lastX, anchorValue: lastValue, fine: optionHeld)
            }
            result = relativeValue(atX: x, track: track)
        }
        lastX = x
        guard let value = result, value != lastValue else { return nil }
        lastValue = value
        return value
    }

    private func relativeValue(atX x: Double, track: Track) -> Double? {
        guard case .relative(let anchorX, let anchorValue, let fine) = mode else { return nil }
        let usable = track.width - track.thumbWidth
        guard usable > 0 else { return nil }
        let span = track.range.upperBound - track.range.lowerBound
        let delta = (x - anchorX) * span / usable / (fine ? Self.fineDivisor : 1)
        return Swift.min(Swift.max(anchorValue + delta, track.range.lowerBound), track.range.upperBound)
    }
}

/// The slider's knob. Drawn as its own view so the keyboard-focus ring can be rendered (and tested) without real focus: the system
/// focus effect is switched off on the slider, so a focused knob shows this outline instead.
struct ThinSliderThumb: View {
    let width: CGFloat
    let height: CGFloat
    let isFocused: Bool
    /// A thin dark hairline just inside the thumb's edge, used only over a colour-gradient track so the white thumb stays
    /// visible on a pale end (amber, yellow). Off by default: the plain thumb is drawn exactly as before.
    var hasHairline: Bool = false

    var body: some View {
        // No shadow on the thumb: flat, like the rest of the editor.
        Capsule()
            .fill(Color.white)
            .frame(width: width, height: height)
            .overlay {
                if hasHairline {
                    Capsule().strokeBorder(Color.black.opacity(0.55), lineWidth: 0.75)
                }
            }
            .overlay(Capsule().stroke(Theme.selectedOutline, lineWidth: 1.5).padding(-3).opacity(isFocused ? 1 : 0))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// A thin flat-track slider matching Apple Photos' Adjust panel look —
/// replaces the native `Slider`'s glossy 3D knob, which can't be
/// restyled to match. Drop-in for `Slider(value:in:)`: same
/// `Binding<Double>`/`ClosedRange<Double>` API, same row height.
struct ThinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// D6 (IMPROVEMENTS.md): the announced `accessibilityValue` defaulted
    /// to a bare 0-100% of `range`, which reviewer-caught mismatches what's
    /// actually on screen for most rows — a Temperature row shows "6500K"
    /// but VoiceOver said "62%"; an EV row shows "0.00 EV" but VoiceOver
    /// said "50%". Callers that already have a real formatted string (e.g.
    /// `EditSliderRow`'s own `format` closure) pass it here instead. `nil`
    /// keeps the previous percent behavior — additive, no call-site changes
    /// required elsewhere.
    var valueDescription: ((Double) -> String)? = nil
    /// D58-2: colour stops (left to right) for a gradient track. `nil` keeps the plain grey track with the dimmer filled part.
    /// A gradient replaces the filled part (a bar filled up to the thumb would muddy a bipolar ramp; the thumb alone marks the
    /// value) and gives the thumb a hairline outline.
    var track: [Color]? = nil
    /// A double-click on the track (the second mouse-down) calls this. With it set, a press writes nothing until the pointer has
    /// moved `ThinSliderDrag.moveThreshold` (so a click does not jump the thumb); `nil` keeps click-to-jump.
    var onDoubleClick: (() -> Void)? = nil

    /// The filled part of the track is a dimmer white than the thumb, so the thumb is the one bright mark.
    static let filledTrackOpacity = 0.55
    private let trackHeight: CGFloat = 4
    private let thumbWidth: CGFloat = 5
    private let thumbHeight: CGFloat = 18
    private let rowHeight: CGFloat = 22
    /// Keyboard focus is reached with Tab only (full keyboard access): a drag deliberately does NOT take focus, because the image
    /// pane and the Library grid take it back on click and a slider stealing it would stop their arrow-key handling.
    @FocusState private var isFocused: Bool
    /// The current press's `startLocation` and its drag maths. A different `startLocation` begins a new session (the tone curve
    /// editor's self-healing rule), so a dropped `onEnded` cannot leak a stale session into the next press.
    @State private var dragStart: CGPoint?
    @State private var drag: ThinSliderDrag?

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let fraction = ThinSliderGeometry.fraction(of: value, in: range)
            let thumbX = ThinSliderGeometry.thumbCenterX(
                fraction: fraction, trackWidth: trackWidth, thumbWidth: thumbWidth
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: trackHeight)
                if let track, track.count >= 2 {
                    Capsule()
                        .fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                        .frame(height: trackHeight)
                } else {
                    Capsule()
                        .fill(Color.white.opacity(Self.filledTrackOpacity))
                        .frame(width: thumbX, height: trackHeight)
                }
                ThinSliderThumb(
                    width: thumbWidth, height: thumbHeight, isFocused: isFocused,
                    hasHairline: (track?.count ?? 0) >= 2
                )
                    .offset(x: thumbX - thumbWidth / 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let track = ThinSliderDrag.Track(
                            width: Double(trackWidth), thumbWidth: Double(thumbWidth), range: range
                        )
                        let optionHeld = NSEvent.modifierFlags.contains(.option)
                        let x = Double(gesture.location.x)
                        if dragStart != gesture.startLocation || drag == nil {
                            dragStart = gesture.startLocation
                            let (session, start) = ThinSliderDrag.begin(
                                x: Double(gesture.startLocation.x), value: value,
                                clickCount: onDoubleClick == nil ? 1 : Self.pressClickCount(),
                                optionHeld: optionHeld, canReset: onDoubleClick != nil, track: track
                            )
                            drag = session
                            switch start {
                            case .none: break
                            case .write(let written): value = written
                            case .reset: onDoubleClick?()
                            }
                            if x == Double(gesture.startLocation.x) { return }
                        }
                        guard var session = drag else { return }
                        if let written = session.move(toX: x, optionHeld: optionHeld, track: track) {
                            value = written
                        }
                        drag = session
                    }
                    .onEnded { _ in
                        dragStart = nil
                        drag = nil
                    }
            )
        }
        .frame(height: rowHeight)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
        .accessibilityElement()
        .accessibilityValue(Text(
            valueDescription?(value) ?? String(format: "%.0f%%", ThinSliderGeometry.fraction(of: value, in: range) * 100)
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = ThinSliderGeometry.incremented(value, in: range)
            case .decrement: value = ThinSliderGeometry.decremented(value, in: range)
            @unknown default: break
            }
        }
    }

    /// The click count of the mouse-down that started this press (1 when the current event is not one). UNVERIFIED: that the first
    /// `onChanged` of a `minimumDistance: 0` drag runs while `NSApp.currentEvent` is still that mouse-down (the grid only relies on it
    /// inside `onTapGesture`); until checked live, a track double-click may not report 2.
    private static func pressClickCount() -> Int {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return 1 }
        return event.clickCount
    }

    /// Left / Down and Right / Up step, Home / End jump; Shift steps four at a time, Option a quarter of a step. Command / Control are
    /// left alone (menu shortcuts such as ⌘← win). Plain arrows carry the numeric-pad / function flags, so the check is `isDisjoint`, not "is empty".
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control]) else { return .ignored }
        let key: ThinSliderGeometry.Key
        switch press.key {
        case .leftArrow, .downArrow: key = .decrease
        case .rightArrow, .upArrow: key = .increase
        case .home: key = .minimum
        case .end: key = .maximum
        default: return .ignored
        }
        value = ThinSliderGeometry.keyed(
            value, key: key, coarse: press.modifiers.contains(.shift),
            fine: press.modifiers.contains(.option), in: range
        )
        return .handled
    }
}
