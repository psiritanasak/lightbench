import Foundation

/// How visible a Library grid cell's chrome is: the star / flag / options row under the thumbnail and the unselected check circle on it.
/// Both only DIM (opacity) — never removed — so the controls keep their size, hit area and VoiceOver presence (a touchpad has no hover, and
/// the cell's width budget was measured against the full row). A cell the pointer is on, a selected or keyboard-focused one, and any photo
/// that carries a rating, flag or label (information that must stay readable) are drawn at full strength.
enum CellChrome {
    /// The resting opacity of the control row / the unselected check circle (tune here).
    static let dimmedRowOpacity = 0.3
    static let dimmedCheckOpacity = 0.4

    static func rowOpacity(isHovered: Bool, isSelected: Bool, isFocused: Bool, hasRatingFlagOrLabel: Bool) -> Double {
        (isHovered || isSelected || isFocused || hasRatingFlagOrLabel) ? 1 : dimmedRowOpacity
    }

    /// The check circle: full when hovered, when this photo is selected, or when ANY photo is selected (so building a multi-selection
    /// stays easy without hunting for faint circles).
    static func checkOpacity(isHovered: Bool, isSelected: Bool, anySelected: Bool) -> Double {
        (isHovered || isSelected || anySelected) ? 1 : dimmedCheckOpacity
    }
}
