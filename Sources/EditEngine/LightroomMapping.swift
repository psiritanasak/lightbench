import Foundation
import CoreGraphics

/// Maps Adobe Camera Raw (`crs:`) develop settings onto this app's own `EditState`. APPROXIMATE by nature: Lightbench renders
/// with its own pipeline (Core Image / `CIRAWFilter`), not Adobe's, so the same number does not give the same pixels. The
/// import is therefore a starting point, and the result alert says so.
///
/// READ-ONLY: nothing here writes `crs:` anywhere.
///
/// EVIDENCE, stated per tier rather than dressed up (spike: one Nikon D610 NEF + its Lightroom XMP + Lightroom's own 600x600
/// render, ONE photo, ONE process version (Camera Raw 8.5, PV 6.7 = "2012"); numbers in `LightroomImportProbeTests`'s doc comment):
/// - MEASURED-CONSISTENT: `Exposure2012` -> `exposureEV`, 1 stop = 1 EV. In the builder's spike (not the probe test) a sweep of
///   our `exposureEV` over {0.3, 0.5, 0.65, 0.8, 1.0} with the white balance FIXED at 3500 and nothing else applied had its
///   minimum error at 0.65-0.8 against the file's +0.65. This is the ONLY field checked against Lightroom.
/// - NOMINAL (same-named slider, same +-100 range and direction by definition, the scale 1/100 is a CONVENTION): every other
///   mapped slider. The one photo could NOT validate them (it only exercises Contrast +28, Whites +21 and Vibrance +10, and Camera
///   Raw's base tone curve differs from `CIRAWFilter`'s), and the confirmation dialog and result alert say so plainly
///   (`LightroomImportModel.honestyNote`) and list which nominal fields were applied (`Plan.appliedNominal`).
/// - NOT CALIBRATED, left unmapped: `Contrast2012`. Once Exposure was matched, adding our contrast 0.28 made the match to
///   Lightroom's own render measurably WORSE on the test photo (mean error 0.0680 -> 0.0781 with it), so it is reported under
///   `ignored` instead of imported.
/// - NOT MAPPED (counted by name in `ignored` when they carry a non-default value): White Balance Temperature/Tint (Camera Raw's
///   value is an absolute illuminant, ours is relative to a 6500 neutral and the as-shot value is not in the XMP), Sharpness
///   (Camera Raw's raw default is 25, no measurable gain), Color Grade / Split Toning, lens, calibration, `CropAngle`, and the
///   structures this importer never interprets (masks, spot removal, Looks/profiles: named in `ignored`, see `AdobeCameraRawSettings.structuredNames`).
/// - ABSENT KEYS NEVER ERASE: only settings the file actually carries are written (`Plan.presentRules`, `presentCurves`,
///   `hasGrayscaleKey`); a PRESENT zero still replaces (preset semantics). A file in an older process version (PV2010/2003) is refused.
/// - CROP semantics (`CropLeft/Top/Right/Bottom` as edge positions of the oriented image) are UNVALIDATED: the one measured pair has
///   no crop. The crop is refused, not clamped, when the photo is not upright or an inset would exceed `maximumCropInset`.
enum LightroomMapping {
    // MARK: - Result

    typealias Result = (state: EditState, mapped: [String], ignored: [String])

    /// Everything one import decided; `merge` applies it. `state` is a full identity-based state (only the imported fields differ).
    struct Plan: Equatable {
        var state = EditState.identity
        /// Camera Raw names that produced a non-identity value.
        var mapped: [String] = []
        var ignored: [String] = []
        /// Rule keys / curve names / the grayscale flag the file actually CARRIES (a present zero counts, an absent key does not).
        var presentRules: Set<String> = []
        var presentCurves: Set<String> = []
        var hasGrayscaleKey = false
        /// The crop insets in `state` are to be applied.
        var includesCrop = false
        /// `mapped` entries that use a nominal scale (everything but Exposure; curves, B&W and crop are not scales).
        var appliedNominal: [String] = []
        /// Non-nil: the file cannot be imported at all (older process version); nothing is applied.
        var refusal: String?
        /// Non-nil: a requested crop was refused (the rest still imports).
        var cropRefusal: String?
        /// Non-nil (1...3, clockwise): the file's `tiff:Orientation` differs from the photo's own EXIF orientation by this many
        /// quarter turns (rotation-only values 1/3/6/8), and `merge` sets `EditState.rotationQuarterTurns` to it. Nil when the file
        /// agrees with the photo, or carries no orientation; also nil (and named in `ignored`, as "Orientation (mirrored)" or
        /// "Orientation (photo's unreadable)") when an orientation is mirrored or the photo's own cannot be read. A file that agrees NEVER resets a rotation the user made by hand.
        var rotationQuarterTurns: Int?
    }

    /// Largest crop inset accepted (this app's own limit); a larger one is refused rather than silently shrunk.
    static let maximumCropInset = 0.45

    // MARK: - Table

    /// One scalar rule: Camera Raw name -> an `EditState` field, `value = raw / divisor` clamped to `range`.
    struct Rule {
        let key: String
        let path: WritableKeyPath<EditState, Double>
        let divisor: Double
        let range: ClosedRange<Double>
        let isMeasured: Bool
    }

    private static func rule(_ key: String, _ path: WritableKeyPath<EditState, Double>, divisor: Double = 100,
                             range: ClosedRange<Double> = -1...1, measured: Bool = false) -> Rule {
        Rule(key: key, path: path, divisor: divisor, range: range, isMeasured: measured)
    }

    /// The 8 colour bands, in Camera Raw's own spelling, with the three paths each band owns.
    nonisolated(unsafe) private static let bands: [(name: String, hue: WritableKeyPath<EditState, Double>, saturation: WritableKeyPath<EditState, Double>, luminance: WritableKeyPath<EditState, Double>)] = [
        ("Red", \.redHue, \.redSaturation, \.redLuminance),
        ("Orange", \.orangeHue, \.orangeSaturation, \.orangeLuminance),
        ("Yellow", \.yellowHue, \.yellowSaturation, \.yellowLuminance),
        ("Green", \.greenHue, \.greenSaturation, \.greenLuminance),
        ("Aqua", \.aquaHue, \.aquaSaturation, \.aquaLuminance),
        ("Blue", \.blueHue, \.blueSaturation, \.blueLuminance),
        ("Purple", \.purpleHue, \.purpleSaturation, \.purpleLuminance),
        ("Magenta", \.magentaHue, \.magentaSaturation, \.magentaLuminance)
    ]

    nonisolated(unsafe) static let rules: [Rule] = {
        var list: [Rule] = [
            rule("Exposure2012", \.exposureEV, divisor: 1, range: -5...5, measured: true),
            rule("Highlights2012", \.curvesHighlights),
            rule("Shadows2012", \.curvesShadows),
            rule("Whites2012", \.whites),
            rule("Blacks2012", \.blackPoint),
            rule("Texture", \.texture),
            rule("Clarity2012", \.clarity),
            rule("Dehaze", \.dehaze),
            rule("Vibrance", \.vibrance),
            rule("Saturation", \.hslSaturation),
            rule("LuminanceSmoothing", \.noiseReduction, range: 0...1),
            rule("GrainAmount", \.grain, range: 0...1),
            // Camera Raw: NEGATIVE darkens the corners. This app: POSITIVE darkens. Hence the sign.
            rule("PostCropVignetteAmount", \.vignetteStrength, divisor: -100)
        ]
        for band in bands {
            list.append(rule("HueAdjustment" + band.name, band.hue))
            list.append(rule("SaturationAdjustment" + band.name, band.saturation))
            list.append(rule("LuminanceAdjustment" + band.name, band.luminance))
        }
        return list
    }()

    /// Rules whose scale is a convention, not a measurement (everything except `isMeasured`).
    static var nominalNames: [String] { rules.filter { !$0.isMeasured }.map(\.key) }

    /// The curve names this import reads, and where they land.
    nonisolated(unsafe) private static let curveTargets: [(key: String, path: WritableKeyPath<EditState, [ToneCurvePoint]>)] = [
        ("ToneCurvePV2012", \.toneCurvePoints),
        ("ToneCurvePV2012Red", \.toneCurvePointsRed),
        ("ToneCurvePV2012Green", \.toneCurvePointsGreen),
        ("ToneCurvePV2012Blue", \.toneCurvePointsBlue)
    ]

    // MARK: - Ignored bookkeeping

    /// Camera Raw's own factory values: a setting sitting at one of these carries no user intent and is not counted as ignored.
    private static let factoryDefaults: [String: Double] = [
        "Sharpness": 25, "SharpenRadius": 1.0, "SharpenDetail": 25, "SharpenEdgeMasking": 0,
        "ColorNoiseReduction": 25, "ColorNoiseReductionDetail": 50, "ColorNoiseReductionSmoothness": 50,
        "ParametricShadowSplit": 25, "ParametricMidtoneSplit": 50, "ParametricHighlightSplit": 75,
        "DefringePurpleHueLo": 30, "DefringePurpleHueHi": 70, "DefringeGreenHueLo": 40, "DefringeGreenHueHi": 60,
        "PerspectiveScale": 100, "PostCropVignetteMidpoint": 50, "PostCropVignetteFeather": 50, "PostCropVignetteRoundness": 0,
        "PostCropVignetteStyle": 1, "PostCropVignetteHighlightContrast": 0,
        "GrainSize": 25, "GrainFrequency": 50, "ColorGradeBlending": 50, "ColorGradeGlobalSat": 0,
        "SplitToningBalance": 0, "CropConstrainToWarp": 0
    ]

    /// Names that are file bookkeeping, never user settings.
    private static let bookkeeping: Set<String> = [
        "Version", "ProcessVersion", "RawFileName", "HasSettings", "AlreadyApplied", "CameraProfileDigest", "ToneCurveName",
        "ToneCurveName2012", "WhiteBalance", "AutoWhiteVersion", "LensProfileSetup", "HasCrop", "CropConstrainToWarp",
        "CropLeft", "CropTop", "CropRight", "CropBottom", "ClipboardOrientation", "ClipboardAspectRatio", "UprightVersion",
        "UprightCenterMode", "UprightFocalMode", "UprightFourSegmentsCount", "OverrideLookVignette", "SubsetRetouch",
        "MaskMergeOption", "MaskDeleteOption", "CropAngle", "ConvertToGrayscale", "CameraProfile"
    ]

    // MARK: - Mapping

    /// Calibration notes for settings deliberately not imported although the slider exists here.
    private static let uncalibrated: [String: String] = [
        "Contrast2012": "not calibrated: made the match worse on the test photo"
    ]

    /// The 2012-process tone keys: a file carrying none of them says nothing about this process version's tone sliders.
    private static let processVersion2012Keys = ["Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012", "Clarity2012"]
    /// Pre-2012 tone keys (PV2010 / PV2003).
    private static let legacyToneKeys = ["Exposure", "Brightness", "Contrast", "Shadows", "FillLight", "Recovery"]

    /// Camera Raw's `ProcessVersion` numbering: 5.0 = PV2003, 5.7 = PV2010, 6.7 = PV2012 (11.0 and later are PV2012's successors, which keep
    /// the 2012 key names). Anything below this is refused.
    static let firstSupportedProcessVersion = 6.7

    /// See `Plan`. `cropAllowed` is false when the photo's orientation is not upright; `photoOrientation` (EXIF 1...8) is compared with the
    /// packet's own `tiff:Orientation`; `target` is the edit the plan will land on (a crop is refused over flip / straighten / perspective /
    /// scale / aspect, whose insets would land on other edges). All three only matter when `includeCrop`.
    static func plan(from settings: AdobeCameraRawSettings, includeCrop: Bool = false, cropAllowed: Bool = true,
                     photoOrientation: Int? = nil, target: EditState? = nil) -> Plan {
        var plan = Plan()
        var handled = Set<String>()

        // An older process version: the 2012 sliders are absent (or stray) and the legacy ones mean something else. A PARSED version
        // decides; only a file with no version at all falls back to its keys.
        let has2012 = processVersion2012Keys.contains { settings.number($0) != nil } || settings.curve("ToneCurvePV2012") != nil
        let version = settings.text("ProcessVersion")
        let hasLegacyKeys = legacyToneKeys.contains { settings.number($0) != nil }
        let tooOld: Bool
        if let parsed = version.flatMap(AdobeCameraRawSettings.parseNumber) {
            tooOld = parsed < firstSupportedProcessVersion
        } else {
            tooOld = !has2012 && hasLegacyKeys
        }
        if tooOld {
            plan.refusal = "This file uses an older Camera Raw process version (\(version ?? "legacy tone settings")); nothing was imported."
            return plan
        }

        for rule in rules {
            handled.insert(rule.key)
            guard let raw = settings.number(rule.key) else { continue }
            plan.presentRules.insert(rule.key)
            let value = min(max(raw / rule.divisor, rule.range.lowerBound), rule.range.upperBound) + 0.0  // + 0.0 turns -0.0 into 0.0
            plan.state[keyPath: rule.path] = value
            if value != EditState.identity[keyPath: rule.path] {
                plan.mapped.append(rule.key)
                if !rule.isMeasured { plan.appliedNominal.append(rule.key) }
            }
        }

        if let grayscale = settings.flag("ConvertToGrayscale") {
            plan.hasGrayscaleKey = true
            plan.state.blackAndWhite = grayscale
            if grayscale { plan.mapped.append("ConvertToGrayscale") }
        }

        for target in curveTargets {
            handled.insert(target.key)
            guard let raw = settings.curve(target.key) else { continue }
            plan.presentCurves.insert(target.key)
            let points = curvePoints(from: raw)
            plan.state[keyPath: target.path] = points
            if !points.isEmpty {
                plan.mapped.append(target.key)
                plan.appliedNominal.append(target.key)   // curves are approximate too: Camera Raw's work in a different tone space
            }
        }

        // Rotation: the packet's orientation relative to the photo's own (both must be rotation-only values).
        var orientationIgnored = false
        var photoOrientationUnreadable = false
        if let packet = settings.tiffOrientation, photoOrientation == nil, packet != 1 { photoOrientationUnreadable = true }
        if let packet = settings.tiffOrientation, let photo = photoOrientation, packet != photo {
            if let turns = QuarterTurn.relativeTurns(packetOrientation: packet, photoOrientation: photo) {
                // Two different rotation-only orientations always differ by 1...3 turns, so this is never 0.
                plan.rotationQuarterTurns = turns
                plan.mapped.append("Orientation")
            } else {
                orientationIgnored = true
            }
        }

        var cropRequested = includeCrop && settings.flag("HasCrop") == true
        if cropRequested {
            if let refusal = cropProblem(settings, cropAllowed: cropAllowed, photoOrientation: photoOrientation, target: target,
                                         rotating: plan.rotationQuarterTurns != nil) {
                plan.cropRefusal = refusal
                cropRequested = false
            } else {
                applyCrop(settings, to: &plan.state)
                if cropInsetsPresent(plan.state) { plan.mapped.append("Crop") }
                plan.includesCrop = true
            }
        }

        plan.ignored = ignoredNames(in: settings, handled: handled, cropImported: plan.includesCrop, cropRefused: plan.cropRefusal != nil)
        if orientationIgnored { plan.ignored = (plan.ignored + ["Orientation (mirrored)"]).sorted() }
        if photoOrientationUnreadable { plan.ignored = (plan.ignored + ["Orientation (photo's unreadable)"]).sorted() }
        plan.mapped.sort()
        plan.appliedNominal.sort()
        return plan
    }

    /// The mapped `EditState` (see `Plan.state`), the Camera Raw names that produced a non-identity value (`mapped`), and the names of
    /// settings that carry a non-default value but were not imported (`ignored`, sorted). Never throws; a malformed value is absent.
    static func editState(from settings: AdobeCameraRawSettings, includeCrop: Bool = false) -> Result {
        let plan = plan(from: settings, includeCrop: includeCrop)
        return (plan.state, plan.mapped, plan.ignored)
    }

    // MARK: - Merging

    /// `plan` laid over `target`: ONLY the fields the file actually CARRIES are taken (a present zero replaces, like a preset; an
    /// ABSENT key never erases the user's value), plus the crop insets when `plan.includesCrop`. Everything else stays `target`'s own:
    /// the groups this import does not map (white balance, Looks/Styles, Levels, Color Grading, point colours...), geometry (crop
    /// unless included), spots and the RAW-decode fields. Masks and red-eye points stay too, but an imported rotation turns them with the picture. A deliberate difference from `applyingPreset(onto:)`, which
    /// would reset every unmapped group (it assumes a complete look; a `crs:` file, or a preset exported from Lightroom, is not).
    static func merge(_ plan: Plan, onto target: EditState) -> EditState {
        guard plan.refusal == nil else { return target }
        var result = target
        for rule in rules where plan.presentRules.contains(rule.key) { result[keyPath: rule.path] = plan.state[keyPath: rule.path] }
        for curve in curveTargets where plan.presentCurves.contains(curve.key) { result[keyPath: curve.path] = plan.state[keyPath: curve.path] }
        if plan.hasGrayscaleKey { result.blackAndWhite = plan.state.blackAndWhite }
        // Rotation first, so the CURRENT crop follows the picture; an included crop is then written over it (the importer
        // refuses a crop while it rotates, so the two never combine).
        if let turns = plan.rotationQuarterTurns { result = result.settingStoredQuarterTurns(turns) }
        if plan.includesCrop {
            result.cropInsetLeft = plan.state.cropInsetLeft
            result.cropInsetTop = plan.state.cropInsetTop
            result.cropInsetRight = plan.state.cropInsetRight
            result.cropInsetBottom = plan.state.cropInsetBottom
        }
        return result
    }

    // MARK: - What a merge changes

    /// The clockwise on-screen turn (1...3) that setting the stored count to `stored` makes to `target`, or nil when it already has it.
    static func screenTurns(settingStored stored: Int, onto target: EditState) -> Int? {
        let delta = QuarterTurn.normalized(stored - target.rotationQuarterTurns)
        guard delta != 0 else { return nil }
        return target.flipHorizontal != target.flipVertical ? QuarterTurn.normalized(-delta) : delta
    }

    /// What merging `plan` onto an edit actually changes, for the result message.
    struct Changes: Equatable {
        /// Sliders / switches / curves set to a non-default value that differ from before (crs names, `Crop`).
        var setNames: [String] = []
        /// Sliders the file carries at 0 that were non-zero before (crs names).
        var resetSliders: [String] = []
        /// Point curves the file carries straight that were bent before.
        var resetCurves: [String] = []
        /// A full-frame crop in the file removed a crop the photo had.
        var clearedCrop = false
        var resetBlackAndWhite = false
        /// The turn the import makes ON SCREEN, clockwise quarter turns 1...3, relative to the current edit (nil when the edit already
        /// has the file's rotation). Not the stored count: with exactly one flip on, the stored direction is inverted.
        var rotationScreenTurns: Int?
        var isEmpty: Bool {
            setNames.isEmpty && resetSliders.isEmpty && resetCurves.isEmpty && !resetBlackAndWhite && !clearedCrop && rotationScreenTurns == nil
        }
    }

    static func changes(of plan: Plan, onto target: EditState) -> Changes {
        var out = Changes()
        guard plan.refusal == nil else { return out }
        for rule in rules where plan.presentRules.contains(rule.key) {
            let new = plan.state[keyPath: rule.path], old = target[keyPath: rule.path]
            guard new != old else { continue }
            if new == EditState.identity[keyPath: rule.path] { out.resetSliders.append(rule.key) } else { out.setNames.append(rule.key) }
        }
        for curve in curveTargets where plan.presentCurves.contains(curve.key) {
            let new = plan.state[keyPath: curve.path], old = target[keyPath: curve.path]
            guard new != old else { continue }
            if new.isEmpty { out.resetCurves.append(curve.key) } else { out.setNames.append(curve.key) }
        }
        if plan.hasGrayscaleKey, plan.state.blackAndWhite != target.blackAndWhite {
            if plan.state.blackAndWhite { out.setNames.append("ConvertToGrayscale") } else { out.resetBlackAndWhite = true }
        }
        if plan.includesCrop,
           (plan.state.cropInsetLeft, plan.state.cropInsetTop, plan.state.cropInsetRight, plan.state.cropInsetBottom)
            != (target.cropInsetLeft, target.cropInsetTop, target.cropInsetRight, target.cropInsetBottom) {
            if cropInsetsPresent(plan.state) { out.setNames.append("Crop") } else { out.clearedCrop = true }
        }
        if let turns = plan.rotationQuarterTurns { out.rotationScreenTurns = screenTurns(settingStored: turns, onto: target) }
        out.setNames.sort(); out.resetSliders.sort(); out.resetCurves.sort()
        return out
    }

    // MARK: - Curves

    /// Camera Raw's 0...255 points -> this app's 0...1 points: sorted by x, clamped, near-duplicate x dropped, thinned to
    /// `MonotoneToneCurve.maximumPointCount` (both end points kept; the points that bend the curve least go first). An identity (straight) curve or
    /// fewer than two usable points is `[]` (this app's "no curve").
    static func curvePoints(from raw: [CGPoint]) -> [ToneCurvePoint] {
        var points = raw
            .map { ToneCurvePoint(x: min(max($0.x / 255, 0), 1), y: min(max($0.y / 255, 0), 1)) }
            .sorted { $0.x < $1.x }
        var spaced: [ToneCurvePoint] = []
        for point in points {
            if let last = spaced.last, point.x - last.x < 0.001 { continue }
            spaced.append(point)
        }
        points = spaced
        guard points.count >= 2 else { return [] }
        let cap = MonotoneToneCurve.maximumPointCount
        // Over the cap: repeatedly drop the interior point whose removal bends the (piecewise-linear) curve the least, so the
        // points that carry the shape survive and both end points always stay.
        while points.count > cap {
            var bestIndex = 1
            var bestError = Double.infinity
            for i in 1..<(points.count - 1) {
                let a = points[i - 1], b = points[i], c = points[i + 1]
                let t = (b.x - a.x) / (c.x - a.x)
                let error = abs(b.y - (a.y + t * (c.y - a.y)))
                if error < bestError { bestError = error; bestIndex = i }
            }
            points.remove(at: bestIndex)
        }
        if points.allSatisfy({ abs($0.x - $0.y) < 0.0005 }) { return [] }
        return points
    }

    // MARK: - Crop

    /// `CropLeft/Top/Right/Bottom` are EDGE POSITIONS as fractions of the oriented image (`CropRight = 0.9` keeps up to 90 %),
    /// this app's insets are distances from each edge. UNVALIDATED against a file: the one measured pair has no crop.
    /// `CropAngle` is deliberately not imported (rotation direction unmeasured).
    private static func rawInsets(_ s: AdobeCameraRawSettings) -> [Double] {
        [s.number("CropLeft") ?? 0, s.number("CropTop") ?? 0, 1 - (s.number("CropRight") ?? 1), 1 - (s.number("CropBottom") ?? 1)]
    }

    /// Why a requested crop cannot be imported faithfully, or nil. Refused, never clamped to a different region.
    private static func cropProblem(_ s: AdobeCameraRawSettings, cropAllowed: Bool, photoOrientation: Int?, target: EditState?,
                                    rotating: Bool = false) -> String? {
        if rotating {
            return "The crop was not imported: this import also rotates the picture (the file's orientation differs from the photo's), and Camera Raw's crop edges are unvalidated for a rotated photo."
        }
        if !cropAllowed {
            return "The crop was not imported: this photo is rotated by its own orientation, and Camera Raw's crop edges are unvalidated for that."
        }
        if let packet = s.tiffOrientation, let photo = photoOrientation, packet != photo {
            return "The crop was not imported: the file says the photo's orientation is \(packet), but this photo's is \(photo), so the crop edges would not match."
        }
        if let angle = s.number("CropAngle"), angle != 0 {
            return "The crop was not imported: it is rotated (CropAngle \(angle)), which this app's straight crop cannot represent."
        }
        if let target, geometryIsActive(target) {
            return "The crop was not imported: this photo already has a flip, straighten, perspective or scale edit, which would put the crop on other edges. Reset those first."
        }
        if rawInsets(s).contains(where: { $0 < -0.001 || $0 > maximumCropInset }) {
            return "The crop was not imported: it removes more than \(Int(maximumCropInset * 100)) % from an edge, which this app's crop cannot represent."
        }
        return nil
    }

    /// True when the edit has a flip, straighten, perspective, scale or aspect change (crop insets are not counted).
    static func geometryIsActive(_ state: EditState) -> Bool {
        state.rotationQuarterTurns != 0 || state.flipHorizontal || state.flipVertical || state.straightenAngle != 0 || state.verticalPerspective != 0
            || state.horizontalPerspective != 0 || state.transformScale != 1 || state.transformAspect != 0
    }

    private static func applyCrop(_ s: AdobeCameraRawSettings, to state: inout EditState) {
        let insets = rawInsets(s).map { max($0, 0) + 0.0 }
        state.cropInsetLeft = insets[0]
        state.cropInsetTop = insets[1]
        state.cropInsetRight = insets[2]
        state.cropInsetBottom = insets[3]
    }

    private static func cropInsetsPresent(_ state: EditState) -> Bool {
        state.cropInsetLeft != 0 || state.cropInsetTop != 0 || state.cropInsetRight != 0 || state.cropInsetBottom != 0
    }

    // MARK: - Ignored

    /// Legacy (process 2003/2010) curves: inactive in a 2012 file that carries its own PV2012 curve.
    private static let legacyCurveNames = ["ToneCurve", "ToneCurveRed", "ToneCurveGreen", "ToneCurveBlue"]

    private static func ignoredNames(in s: AdobeCameraRawSettings, handled: Set<String>, cropImported: Bool, cropRefused: Bool) -> [String] {
        var out: [String] = []
        let whiteBalanceIsCustom = s.text("WhiteBalance").map { $0.lowercased() != "as shot" } ?? false
        for (name, text) in s.scalars where !handled.contains(name) && !bookkeeping.contains(name) {
            // White balance values are only user intent when the file says the balance was set by hand.
            if (name == "Temperature" || name == "Tint"), !whiteBalanceIsCustom { continue }
            if let number = AdobeCameraRawSettings.parseNumber(text) {
                if number == 0 { continue }
                if let factory = factoryDefaults[name], number == factory { continue }
                if let note = uncalibrated[name] { out.append("\(name) (\(note))") } else { out.append(name) }
            }
        }
        // Structures (masks, spot removal, Looks/profiles...) are never interpreted: name them.
        out.append(contentsOf: s.structuredNames.filter { !bookkeeping.contains($0) })
        // Curves nothing maps: legacy ones count only when the file has no PV2012 curve of its own to supersede them.
        let carries2012Curve = curveTargets.contains { s.curve($0.key) != nil }
        for (name, points) in s.curves where !handled.contains(name) {
            if legacyCurveNames.contains(name), carries2012Curve { continue }
            if !curvePoints(from: points).isEmpty { out.append(name) }
        }
        if s.flag("HasCrop") == true {
            if cropRefused { out.append("Crop (refused)") } else if !cropImported { out.append("Crop (not included)") }
            if let angle = s.number("CropAngle"), angle != 0 { out.append("CropAngle") }
        }
        return Array(Set(out)).sorted()
    }
}
