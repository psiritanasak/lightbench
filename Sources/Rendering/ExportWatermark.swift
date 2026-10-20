import CoreImage
import CoreText
import Foundation

/// Where on the image the watermark sits (a 3x3 grid).
enum WatermarkPosition: String, CaseIterable, Identifiable, Sendable, Codable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top"
        case .topRight: return "Top right"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom right"
        }
    }

    /// -1 / 0 / +1 along x and y (y up, matching Core Image).
    var grid: (x: Int, y: Int) {
        switch self {
        case .topLeft: return (-1, 1)
        case .top: return (0, 1)
        case .topRight: return (1, 1)
        case .left: return (-1, 0)
        case .center: return (0, 0)
        case .right: return (1, 0)
        case .bottomLeft: return (-1, -1)
        case .bottom: return (0, -1)
        case .bottomRight: return (1, -1)
        }
    }
}

/// What the mark is made of.
enum WatermarkKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case text, image

    var id: String { rawValue }
    var label: String { self == .text ? "Text" : "Image" }
}

/// A text or logo mark composited onto exported images (copyright line, name, logo…). Export-only, never part of an edit.
struct ExportWatermark: Sendable, Equatable {
    var isEnabled = false
    /// Text or a logo picture. Both share position, size, opacity and the margin.
    var kind: WatermarkKind = .text
    var text = ""
    /// The `WatermarkLogoStore` id of the chosen logo (kind `.image`). The picture itself is NOT in the settings.
    var logoID: String?
    var position: WatermarkPosition = .bottomRight
    /// Text: the text height as a fraction of the image's SHORT edge, so the mark looks the same at any export size.
    /// Logo: the logo's LONGER side is `logoSizeMultiplier` times this fraction of the short edge (a logo is not a
    /// line of text: at the same numbers it would otherwise be a speck).
    var sizeFraction: Double = 0.04
    /// 0.05...1. Applied as the mark's alpha and blended in LINEAR light (the working space), so a given value looks
    /// somewhat stronger than the same percentage in a gamma-encoded editor (0.7 white over black reads ~0.85 sRGB).
    var opacity: Double = 0.7

    static let sizeRange: ClosedRange<Double> = 0.01...0.15
    static let opacityRange: ClosedRange<Double> = 0.05...1
    static let maximumTextLength = 200
    static let logoSizeMultiplier: Double = 4

    /// Whether applying this watermark changes anything, judged from the settings alone. A logo mark is "active" when a
    /// logo is chosen; whether its file can still be loaded is `inactiveReason(store:)`'s question (a file read).
    var isActive: Bool {
        guard isEnabled else { return false }
        switch kind {
        case .text: return !WatermarkRenderer.normalizedText(text).isEmpty
        case .image: return logoID.map(WatermarkLogoStore.isValidID) ?? false
        }
    }

    /// Why an ENABLED mark would draw nothing, in words for the Export sheet; nil when it will be drawn (or the
    /// watermark is off). The logo file is read, so call it off hot paths (the sheet calls it on appear/choose/remove).
    func inactiveReason(store: WatermarkLogoStore = .shared) -> String? {
        inactiveReason(logoLoads: { id in store.loadImage(id: id) != nil })
    }

    /// Same, with the logo file read supplied by the caller, so the sheet decodes the stored picture ONCE for both the
    /// thumbnail and this message.
    func inactiveReason(logoLoads: (String) -> Bool) -> String? {
        guard isEnabled else { return nil }
        switch kind {
        case .text:
            return WatermarkRenderer.normalizedText(text).isEmpty ? "Type some text to add the mark." : nil
        case .image:
            guard let logoID else { return "Choose a logo to add the mark." }
            guard WatermarkLogoStore.isValidID(logoID) else { return "The saved logo setting is damaged. Choose the logo again." }
            return !logoLoads(logoID) ? "The saved logo can't be found or read any more, so no mark will be added. Choose it again." : nil
        }
    }
}

/// Schema-tolerant persistence, per field (same pattern as `ExportSettings`), with out-of-range numbers clamped.
extension ExportWatermark: Codable {
    private enum CodingKeys: String, CodingKey { case isEnabled, kind, text, logoID, position, sizeFraction, opacity }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExportWatermark()
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? defaults.isEnabled
        // An unknown `kind` (a newer build) or a malformed logo id falls back to today's behaviour: a text mark, no logo.
        kind = (try? container.decodeIfPresent(WatermarkKind.self, forKey: .kind)) ?? defaults.kind
        logoID = (try? container.decodeIfPresent(String.self, forKey: .logoID)).flatMap { WatermarkLogoStore.isValidID($0) ? $0 : nil }
        let storedText = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? defaults.text
        text = String(storedText.prefix(Self.maximumTextLength))
        position = (try? container.decodeIfPresent(WatermarkPosition.self, forKey: .position)) ?? defaults.position
        func bounded(_ value: Double?, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard let value, value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        sizeFraction = bounded(try? container.decodeIfPresent(Double.self, forKey: .sizeFraction), Self.sizeRange, defaults.sizeFraction)
        opacity = bounded(try? container.decodeIfPresent(Double.self, forKey: .opacity), Self.opacityRange, defaults.opacity)
    }
}

enum WatermarkRenderer {
    /// Distance from the image edge to the mark, as a fraction of the short edge.
    static let marginFraction: Double = 0.025
    /// A mark never covers more than this fraction of the image's width (the font shrinks to fit).
    static let maximumWidthFraction: Double = 0.9

    /// Single line: newlines/tabs become spaces, runs collapse, ends trimmed, length capped.
    static func normalizedText(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(ExportWatermark.maximumTextLength))
    }

    /// `image` with the watermark composited on it (unchanged when inactive). Extent never changes.
    static func apply(_ watermark: ExportWatermark, to image: CIImage, logoStore: WatermarkLogoStore = .shared) -> CIImage {
        guard watermark.isActive else { return image }
        let extent = image.extent
        let shortSide = Double(min(extent.width, extent.height))
        guard shortSide >= 1, extent.width.isFinite, extent.height.isFinite else { return image }
        if watermark.kind == .image { return applyLogo(watermark, to: image, logoStore: logoStore) }

        let text = normalizedText(watermark.text)
        let maxWidth = maximumWidthFraction * Double(extent.width)
        // Choose the font size from a MEASUREMENT before rasterizing anything: rasterizing the full-size text first
        // would fail (and silently drop the mark) whenever the unshrunk line is wider than the bitmap limit, even
        // though the shrunk one fits (a 200-character line at the default size on a 6000px photo is ~16600px wide).
        var fontSize = watermark.sizeFraction * shortSide
        if let size = measuredSize(text, fontSize: fontSize), size.width > maxWidth {
            fontSize *= maxWidth / size.width
        }
        // The system font is not exactly linear in size (optical sizes, hinting), so confirm and nudge.
        var rendered = render(text, fontSize: fontSize, opacity: watermark.opacity)
        var attempts = 0
        while let current = rendered, Double(current.image.extent.width) > maxWidth, attempts < 5 {
            fontSize *= maxWidth / Double(current.image.extent.width) * 0.97
            rendered = render(text, fontSize: fontSize, opacity: watermark.opacity)
            attempts += 1
        }
        // Documented limits: no mark is drawn when the font would be under 1px (a short side below ~100px at the
        // smallest size setting) or the text still can't fit after the nudges. The export itself still succeeds.
        guard let (mark, padding) = rendered.map({ ($0.image, $0.padding) }),
              Double(mark.extent.width) <= maxWidth else { return image }

        return composite(mark, padding: padding, position: watermark.position, over: image)
    }

    /// The logo variant of `apply`: the picture is scaled so its longer side is `logoSizeMultiplier * sizeFraction` of the
    /// short edge (never wider/taller than `maximumWidthFraction` of the frame) and drawn with `opacity` as its alpha.
    /// A logo that cannot be loaded or drawn leaves the image untouched (the sheet says so beforehand).
    private static func applyLogo(_ watermark: ExportWatermark, to image: CIImage, logoStore: WatermarkLogoStore) -> CIImage {
        let extent = image.extent
        let shortSide = Double(min(extent.width, extent.height))
        guard let id = watermark.logoID, let logo = logoStore.loadImage(id: id), logo.width > 0, logo.height > 0 else { return image }
        let longSide = Double(max(logo.width, logo.height))
        var scale = watermark.sizeFraction * ExportWatermark.logoSizeMultiplier * shortSide / longSide
        scale = min(scale, maximumWidthFraction * Double(extent.width) / Double(logo.width),
                    maximumWidthFraction * Double(extent.height) / Double(logo.height))
        let width = Int((Double(logo.width) * scale).rounded()), height = Int((Double(logo.height) * scale).rounded())
        guard width >= 1, height >= 1, width <= 16_384, height <= 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        // The logo is drawn into an 8-bit sRGB bitmap, so a wide-gamut (Display P3 / Adobe RGB) export gets the logo's
        // colours clipped to sRGB. Fine for a logo; not a general-purpose overlay path.
        context.interpolationQuality = .high
        context.setAlpha(CGFloat(min(max(watermark.opacity, 0), 1)))
        context.draw(logo, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else { return image }
        return composite(CIImage(cgImage: cgImage), padding: 0, position: watermark.position, over: image)
    }

    /// Places `mark` (extent at the origin) on the position grid, `marginFraction` of the short edge from the edges,
    /// and composites it over `image` in the working space. `padding` is transparent room around the visible pixels.
    private static func composite(_ mark: CIImage, padding: Double, position: WatermarkPosition, over image: CIImage) -> CIImage {
        let extent = image.extent
        let shortSide = Double(min(extent.width, extent.height))
        // Margins are measured to the VISIBLE glyphs, so the bitmap's shadow padding is subtracted. (Vertical gap
        // still follows the glyphs' own bounds, so a descender such as "y" sits a little higher than "o".)
        let margin = marginFraction * shortSide
        let grid = position.grid
        let markWidth = Double(mark.extent.width), markHeight = Double(mark.extent.height)
        let originX: Double, originY: Double
        switch grid.x {
        case -1: originX = Double(extent.minX) + margin - padding
        case 1: originX = Double(extent.maxX) - margin - markWidth + padding
        default: originX = Double(extent.midX) - markWidth / 2
        }
        switch grid.y {
        case -1: originY = Double(extent.minY) + margin - padding
        case 1: originY = Double(extent.maxY) - margin - markHeight + padding
        default: originY = Double(extent.midY) - markHeight / 2
        }
        let placed = mark.transformed(by: CGAffineTransform(translationX: CGFloat(originX.rounded()), y: CGFloat(originY.rounded())))
        return placed.composited(over: image).cropped(to: extent)
    }

    private static func font(size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, CGFloat(size), nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(size), nil)
    }

    private static func line(_ text: String, fontSize: Double) -> CTLine {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font(size: fontSize), kCTForegroundColorFromContextAttributeName: true]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
    }

    /// The bitmap size `render` would need for `text` at `fontSize` (padding included), without drawing it.
    static func measuredSize(_ text: String, fontSize: Double) -> CGSize? {
        guard fontSize >= 1, !text.isEmpty else { return nil }
        let bounds = CTLineGetBoundsWithOptions(line(text, fontSize: fontSize), .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let padding = ceil(fontSize * paddingFraction)
        return CGSize(width: ceil(bounds.width + 2 * padding), height: ceil(bounds.height + 2 * padding))
    }

    /// Room around the glyphs for the shadow, as a fraction of the font size.
    static let paddingFraction: Double = 0.2

    /// White text with a soft dark shadow (legible on light and dark pictures), opacity applied to the whole group,
    /// as a CIImage whose extent starts at the origin, plus the padding around the glyphs. nil when the text
    /// produces no pixels or would not fit a bitmap. Uses CoreText's font cascade, so scripts the primary font lacks
    /// (Thai, CJK, emoji) still render.
    static func render(_ text: String, fontSize: Double, opacity: Double) -> (image: CIImage, padding: Double)? {
        guard let size = measuredSize(text, fontSize: fontSize) else { return nil }
        let textLine = line(text, fontSize: fontSize)
        let bounds = CTLineGetBoundsWithOptions(textLine, .useGlyphPathBounds)
        let padding = ceil(fontSize * paddingFraction)
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Opacity goes on a transparency LAYER, not on the fill colour: colour emoji are bitmaps that ignore the fill
        // colour's alpha (measured: a fill alpha of 0.2 still gave pixel alpha 255), and a layer also composites the
        // shadow and the text as one group so they don't stack.
        context.setAlpha(CGFloat(min(max(opacity, 0), 1)))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.1,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.textPosition = CGPoint(x: padding - bounds.minX, y: padding - bounds.minY)
        CTLineDraw(textLine, context)
        context.endTransparencyLayer()
        guard let cgImage = context.makeImage() else { return nil }
        return (CIImage(cgImage: cgImage), padding)
    }
}
