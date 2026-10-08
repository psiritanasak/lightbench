import Foundation

/// What a rating / flag / colour-label key does to a photo. ONE table shared by the Library grid and the Editor, so the two cannot
/// drift. Pure: no UI, no catalog — callers apply the result (`flagStatus(from:)` / `label(from:)` resolve the toggling rules).
enum PhotoKeyCommand: Equatable {
    case rating(Int)
    /// `nil` = toggle Pick (`.` / `f`): unflagged -> Picked, Picked and Rejected -> unflagged.
    case flag(FlagStatus?)
    /// Applying the photo's current label clears it.
    case label(ColorLabel)

    /// The command for a typed character, or nil if it is not a photo key. `allowsZero` is false in the Editor, where `0` is
    /// "reset zoom" (a rating is cleared there by clicking the current star).
    static func command(for character: Character, allowsZero: Bool = true) -> PhotoKeyCommand? {
        if let digit = character.wholeNumberValue, (0...5).contains(digit) {
            return digit == 0 && !allowsZero ? nil : .rating(digit)
        }
        if let label = ColorLabel.forKey(character) { return .label(label) }
        switch character {
        case ".", "f", "F": return .flag(nil)
        case "p", "P": return .flag(.picked)
        case "x", "X": return .flag(.rejected)
        case "u", "U": return .flag(FlagStatus.none)
        default: return nil
        }
    }

    /// The flag a `.flag` command produces for a photo currently flagged `current` (nil for other kinds).
    func flagStatus(from current: FlagStatus) -> FlagStatus? {
        guard case .flag(let status) = self else { return nil }
        return status ?? current.toggledPick
    }

    /// The label a `.label` command produces for a photo currently labelled `current` (nil for other kinds).
    func label(from current: ColorLabel) -> ColorLabel? {
        guard case .label(let target) = self else { return nil }
        return current.toggled(to: target)
    }
}
