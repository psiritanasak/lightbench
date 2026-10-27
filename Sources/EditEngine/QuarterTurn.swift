import CoreImage
import Foundation
import ImageIO

/// Pure helpers for the 90-degree rotation edit (`EditState.rotationQuarterTurns`): normalisation, the exact
/// Core Image turn the pipeline's first geometry stage runs, the Rotate Left / Right button semantics on an
/// `EditState`, and the Lightroom `tiff:Orientation` -> turns mapping. No UI.
///
/// Convention: a "turn" is ONE CLOCKWISE quarter turn as seen on screen, applied to the photo's own (already
/// EXIF-oriented) picture, BEFORE straighten / perspective / scale / flip / crop.
enum QuarterTurn {
    // MARK: - Normalisation

    /// Any integer folded into 0...3 (negative counts wrap: -1 -> 3).
    static func normalized(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }

    // MARK: - Exact turn

    /// The `CGImagePropertyOrientation` whose `CIImage.oriented(_:)` is a clockwise turn of `turns` quarter turns
    /// (EXIF 6 = "rotate 90 CW to display", 3 = 180, 8 = 270 CW). Verified against a real render by `QuarterTurnTests`.
    static func orientation(forTurns turns: Int) -> CGImagePropertyOrientation {
        switch normalized(turns) {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    /// `image` turned clockwise by `turns` quarter turns, exactly (a pixel permutation, no resampling), with its
    /// extent origin back at (0, 0). The SAME image, untouched, at 0 turns.
    static func apply(_ turns: Int, to image: CIImage) -> CIImage {
        let n = normalized(turns)
        guard n != 0 else { return image }
        let turned = image.oriented(orientation(forTurns: n))
        let extent = turned.extent
        guard !extent.isInfinite, extent.minX != 0 || extent.minY != 0 else { return turned }
        return turned.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    // MARK: - Lightroom orientation

    /// Clockwise quarter turns that display a photo stored with EXIF/TIFF orientation `value`, for the
    /// rotation-only values (1, 6, 3, 8). Mirrored values (2, 4, 5, 7) and anything else: nil.
    static func displayTurns(forOrientation value: Int) -> Int? {
        switch value {
        case 1: return 0
        case 6: return 1
        case 3: return 2
        case 8: return 3
        default: return nil
        }
    }

    /// The rotation edit a Lightroom packet's `tiff:Orientation` asks for, RELATIVE to the photo's own EXIF
    /// orientation (the pixels this app shows are already turned by the latter). Nil when either value is
    /// mirrored / unknown (not importable).
    static func relativeTurns(packetOrientation: Int, photoOrientation: Int) -> Int? {
        guard let packet = displayTurns(forOrientation: packetOrientation),
              let photo = displayTurns(forOrientation: photoOrientation) else { return nil }
        return normalized(packet - photo)
    }

    /// A human phrase for a stored (clockwise) turn count.
    static func phrase(forTurns turns: Int) -> String {
        switch normalized(turns) {
        case 1: return "90° right"
        case 2: return "180°"
        case 3: return "90° left"
        default: return "none"
        }
    }
}

extension EditState {
    /// True when exactly one of the flips is on: a flip conjugates a rotation (a turn after a mirror equals the
    /// opposite turn before it), so the stored turn count must move the OTHER way for the picture to turn the
    /// pressed way on screen.
    private var flipParityIsOdd: Bool { flipHorizontal != flipVertical }

    /// This edit after the picture is turned `quarterTurns` quarter turns CLOCKWISE ON SCREEN (negative =
    /// counter-clockwise): the stored turn count moves by that amount (inverted when exactly one flip is on, so
    /// Rotate Right always looks clockwise), and the four crop insets are permuted so the crop stays on the same
    /// content (Rotate Right: top -> right, right -> bottom, bottom -> left, left -> top). Straighten,
    /// perspective, scale and stretch keep their numbers: they act on the rotated frame. A multiple of 4 returns
    /// `self` unchanged; four single turns return the identical state.
    func rotated(byQuarterTurns quarterTurns: Int) -> EditState {
        let screen = QuarterTurn.normalized(quarterTurns)
        guard screen != 0 else { return self }
        var next = self
        next.rotationQuarterTurns = QuarterTurn.normalized(rotationQuarterTurns + (flipParityIsOdd ? -screen : screen))
        let old = [cropInsetTop, cropInsetRight, cropInsetBottom, cropInsetLeft]   // clockwise order
        // Each inset moves `screen` steps clockwise: new[i] = old[i - screen].
        next.cropInsetTop = old[(0 + 4 - screen) % 4]
        next.cropInsetRight = old[(1 + 4 - screen) % 4]
        next.cropInsetBottom = old[(2 + 4 - screen) % 4]
        next.cropInsetLeft = old[(3 + 4 - screen) % 4]
        return next
    }

    /// This edit with the stored turn count set to `turns` (a file's absolute rotation), the crop following the
    /// content exactly as `rotated(byQuarterTurns:)` does.
    func settingStoredQuarterTurns(_ turns: Int) -> EditState {
        let delta = QuarterTurn.normalized(turns - rotationQuarterTurns)
        return rotated(byQuarterTurns: flipParityIsOdd ? -delta : delta)
    }
}

/// When Rotate Left / Right may run: the ONE rule behind the Photo-menu items and the Crop tab buttons.
enum RotateAvailability {
    static func isEnabled(hasImage: Bool, loadInFlight: Bool, renameWorking: Bool, cullActive: Bool, showLibrary: Bool) -> Bool {
        hasImage && !loadInFlight && !renameWorking && !cullActive && !showLibrary
    }
}
