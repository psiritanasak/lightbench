import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// The app's first shared file-decode chokepoint. Before this file, three
/// call sites (`ImageDocumentModel.load(from:)`, `PhotoExporter.export`,
/// `ThumbnailGenerator.thumbnail(for:maxPixelSize:)`) each decoded a file
/// URL independently. RAW support needed a fourth decode path
/// (`CIRAWFilter`) in all three places, so rather than repeating a
/// RAW-vs-not branch three times, this type is the one place that branch
/// lives — including the EXIF-orientation lookup all three used to read
/// via `ImageDocumentModel`, moved here (Rendering) so `PhotoImporter`
/// (Catalog) calling into this type doesn't transitively reach into UI,
/// matching CLAUDE.md's "Keep modules separated" principle.
///
/// Phase 6 slice 1 scope: decode only. Phase 6 slice 2 added `boostAmount`
/// (Core Image's own RAW tone-curve strength) as the first RAW-native
/// `EditState` field. Phase 6 slice 3 added `rawExposureEV` and
/// `shadowBoostScale`, and — because three RAW-native scalars threaded
/// individually through every call site was already unwieldy at three,
/// let alone the deferred fields still to come — switched `decode`/
/// `decodeDraft` to take the whole `EditState` rather than growing their
/// parameter list per field. Phase 6 slice 4 added
/// `rawWhiteBalanceNeutralPoints`, seeding `CIRAWFilter.neutralLocation`
/// for a true no-search white-balance eyedropper (RAW-only, geometry-
/// identity-only — see that field's own `EditState` doc comment).
/// Phase 6 slice 5 added `rawLuminanceNoiseReductionAdjust` (an additive
/// offset — a multiplicative scale was measured DEAD on this camera's own
/// zero native default, see that field's own `EditState` doc comment),
/// `rawColorNoiseReductionScale`, and `rawSharpnessScale` (both relative
/// scales, same shape as `shadowBoostScale`) — settling the "precedence"
/// question that originally deferred this slice: these run at DECODE
/// time, entirely upstream of and independent from `EditPipeline`'s
/// existing post-decode `noiseReduction`/`sharpness` stages, so the two
/// compose additively rather than conflicting.
/// `applyRawNativeSettings` below is now the ONE place all of them are
/// read (mirrored by `EditState.requiresRawRedecode`, the one place
/// they're compared) — see each field's own `EditState` doc comment for
/// what it does and how its design was shaped by live measurement
/// against the user's real camera. `CIRAWFilter`'s remaining RAW-native
/// controls (`contrastAmount`/`detailAmount`/`moireReductionAmount`,
/// `CIRAWDecoderVersion9` opt-in) are deferred to a later slice;
/// `lensCorrectionEnabled` specifically was MEASURED unsupported on the
/// user's own camera (`isLensCorrectionSupported == false` on three
/// sampled Nikon D610 NEFs) before slice 2 was scoped, so it's deferred
/// deliberately, not an oversight — see CLAUDE.md/PROGRESS.md.
enum RawDecoder {
    /// Serializes every heavy RAW render this app issues —
    /// `materialize`, `ThumbnailGenerator`'s RAW thumbnail path, and
    /// `PhotoExporter`'s RAW export writes — through a single actor,
    /// app-wide.
    ///
    /// Live-caught real bug this exists to fix, a SECOND freeze found
    /// after the per-frame repeat-demosaic bug (`materialize`'s own doc
    /// comment) was already fixed: opening a RAW photo in the Editor
    /// still froze, this time while the Library grid was concurrently
    /// decoding RAW thumbnails in the background for a 930-file import.
    /// `sample`d again: the main thread was `dispatch_sync`-blocked
    /// inside CoreImage's `GetSurfaceFromCacheAndFill`, waiting on TWO
    /// separate `RawCamera-Provider-Render-Queue` worker threads that
    /// were themselves stuck on an internal semaphore deep inside
    /// Apple's private `RawCamera.framework` (opaque, unsymbolicated
    /// frames — nothing further to diagnose from this side). Concurrent
    /// RAW decode requests from different parts of this app appear to
    /// genuinely stall/deadlock each other inside that framework, not
    /// just contend for CPU. The only fix available on this side: never
    /// issue more than one RAW render at a time, app-wide, regardless of
    /// which call site it comes from.
    actor RenderGate {
        static let shared = RenderGate()
        private init() {}

        /// Runs `work` with exclusive access to this app's RAW-decode
        /// machinery. `work` is expected to be a synchronous, CPU/GPU-bound
        /// CoreImage render call (`CIContext.render`/`createCGImage`/
        /// `write*Representation`) — this does not make it non-blocking,
        /// only serial: the calling `Task` suspends here until any other
        /// RAW render in progress elsewhere in the app finishes, then runs
        /// `work` to completion before releasing the next waiter.
        func run<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
            try work()
        }
    }

    /// Thin `@unchecked Sendable` wrapper for a value that needs to cross
    /// `RenderGate`'s actor boundary but isn't (yet) audited `Sendable` by
    /// its own framework (`CVPixelBuffer`, as of this SDK). Only safe to use
    /// when the caller genuinely owns exclusive access until the closure
    /// it's captured into returns — not a general-purpose escape hatch.
    private struct UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value
    }

    /// True if `url` names a camera RAW file, classified via
    /// UniformTypeIdentifiers rather than a hardcoded extension list — the
    /// UTI graph (`public.camera-raw-image`, `.rawImage`) tracks whatever
    /// RAW formats the running OS actually knows how to decode, instead of
    /// this app's own list silently going stale as new cameras ship.
    /// Case-insensitive on the extension, matching every other extension
    /// check in this codebase (`PhotoImporter.supportedExtensions` et al.).
    static func isRaw(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .rawImage)
    }

    /// EXIF/TIFF orientation for `url`, or `.up` if it can't be read —
    /// moved here from `ImageDocumentModel` (its only remaining caller is
    /// this file's own `decode(contentsOf:)`, for the non-RAW path).
    static func exifOrientation(of url: URL) -> CGImagePropertyOrientation {
        readExifOrientation(of: url) ?? .up
    }

    /// `readExifOrientation`, but gated through `RenderGate` and exposed
    /// publicly, `async`, for `ImageDocumentModel` to call directly.
    ///
    /// Deliberately returns the real `nil` on a read failure — UNLIKE
    /// `exifOrientation(of:)` above, which defaults to `.up` — because
    /// this function's one caller (the RAW-native WB-eyedropper
    /// eligibility gate in `ImageDocumentModel.load(from:)`) needs to
    /// tell "confirmed `.up`" apart from "unknown": that gate only opens
    /// on a genuinely-read `.up`, never on a read failure, since
    /// `neutralLocation` was measured to depend on `orientation`'s value
    /// (see `applyRawNativeSettings`'s own doc comment) and an unreadable
    /// orientation could just as easily be non-`.up` as `.up`.
    ///
    /// Gated through `RenderGate` for the same reason every other RAW-
    /// adjacent file touch in this type is: `readExifOrientation` itself
    /// only touches ImageIO, not `CIRAWFilter`/`RawCamera.framework`, but
    /// `decode(contentsOf:)`'s own doc comment already records a
    /// reviewer-caught defect from leaving this SAME function's call
    /// ungated on the main actor once before — this keeps a single "any
    /// RAW-file-adjacent read goes through the gate" discipline rather
    /// than re-litigating which specific APIs are safe to call directly.
    static func confirmedOrientation(of url: URL) async -> CGImagePropertyOrientation? {
        await RenderGate.shared.run {
            readExifOrientation(of: url)
        }
    }

    /// Which of the slice-5 RAW-native adjustments (luminance/color noise
    /// reduction, sharpness) `CIRAWFilter` actually supports for `url` —
    /// `isLuminanceNoiseReductionSupported`/`isColorNoiseReductionSupported`/
    /// `isSharpnessSupported` are per-camera-profile capability flags,
    /// structurally identical to `isLensCorrectionSupported` (measured
    /// `false` for the ORIGINAL slice-2 candidate — see this file's own
    /// type-level doc comment). `ImageDocumentModel` reads this ONCE per
    /// RAW photo load and caches the result, same pattern as
    /// `confirmedOrientation` above and for the same reason: constructing
    /// a `CIRAWFilter` touches `RawCamera.framework`, so it must go
    /// through `RenderGate` and must not be re-done per UI update.
    /// Returns `.unsupported` (all `false`) if construction fails.
    struct RawAdjustmentSupport: Equatable {
        let luminanceNoiseReduction: Bool
        let colorNoiseReduction: Bool
        let sharpness: Bool
        static let unsupported = RawAdjustmentSupport(luminanceNoiseReduction: false, colorNoiseReduction: false, sharpness: false)
    }

    static func confirmedAdjustmentSupport(of url: URL) async -> RawAdjustmentSupport {
        await RenderGate.shared.run {
            guard let filter = CIRAWFilter(imageURL: url) else { return .unsupported }
            return RawAdjustmentSupport(
                luminanceNoiseReduction: filter.isLuminanceNoiseReductionSupported,
                colorNoiseReduction: filter.isColorNoiseReductionSupported,
                sharpness: filter.isSharpnessSupported
            )
        }
    }

    /// Same lookup, but `nil` — not `.up` — when nothing could be read.
    /// Used only by the RAW paths below, where silently substituting `.up`
    /// on a read failure would be actively harmful rather than merely
    /// imprecise: `CIRAWFilter.orientation` already defaults to the file's
    /// own correct EXIF value on its own (measured live against a real
    /// non-identity-orientation NEF — its default `orientation` already
    /// matched ImageIO's independently-read value, and `outputImage` was
    /// already rotated accordingly), so this is only ever assigned when a
    /// value was actually read — never used to overwrite an already-correct
    /// default with a wrong guess for a RAW container ImageIO parses
    /// differently than Core Image's RAW decoder does.
    private static func readExifOrientation(of url: URL) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let raw = properties[kCGImagePropertyOrientation as String] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return nil
        }
        return orientation
    }

    /// Decodes any file this app can open to a `CIImage`, EXIF orientation
    /// applied. Non-RAW files run the exact prior work
    /// (`CIImage(contentsOf:).oriented(...)`) byte-for-byte — `async` only
    /// because Swift requires one signature for both branches; this branch
    /// has no internal suspension point of its own, though the caller may
    /// still observe a hop off its calling actor (the two are called from
    /// the same signature, not the same cost). RAW files go through
    /// `CIRAWFilter`, which does NOT need `.oriented(_:)` chained afterward
    /// — see `readExifOrientation`'s doc comment above.
    ///
    /// Reviewer-caught: an earlier draft only gated `materialize`'s own
    /// render, leaving `CIRAWFilter(imageURL:)`'s construction (which reads
    /// the file's header/camera-profile via the RawCamera framework — real
    /// I/O and CPU work, not free) and the second `CGImageSourceCreateWithURL`
    /// open inside `readExifOrientation` running UNGATED, synchronously, on
    /// whatever actor called `decode` — for `ImageDocumentModel.load(from:)`
    /// that was the main actor, and before `isLoadingImage` was even set.
    /// That's exactly the class of concurrent-RAW-framework-access this
    /// gate exists to prevent, so the ENTIRE RAW branch — construction,
    /// orientation, `.outputImage` — is inside `RenderGate` now, not just
    /// the render step downstream in `materialize`.
    ///
    /// The RAW-native fields in `editState` (Phase 6 slices 2-4) configure
    /// the `CIRAWFilter` instance itself, so they only apply on the RAW
    /// branch — ignored outright for non-RAW files, matching every other
    /// RAW-only parameter here.
    static func decode(contentsOf url: URL, editState: EditState) async -> CIImage? {
        guard isRaw(url) else {
            return CIImage(contentsOf: url)?.oriented(exifOrientation(of: url))
        }
        return await RenderGate.shared.run {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            // Applied FIRST, immediately after construction, before
            // orientation or anything else — see `applyRawNativeSettings`'s
            // own doc comment for why this exact position matters (keeping
            // it identical between this function and `decodeDraft` below is
            // the whole point).
            applyRawNativeSettings(editState, to: filter)
            if let orientation = readExifOrientation(of: url) {
                filter.orientation = orientation
            }
            return filter.outputImage
        }
    }

    /// A fast, lower-quality RAW decode for thumbnails, via `CIRAWFilter`'s
    /// own `isDraftModeEnabled`/`scaleFactor` — exactly what Apple provides
    /// draft mode for, rather than decoding every RAW file at full
    /// resolution just to downsize it afterward. Only meaningful for RAW
    /// files; callers are expected to have already checked `isRaw(url)`
    /// (mirrors `ThumbnailGenerator`'s own non-RAW path, which never calls
    /// this). Construction through `.outputImage` all run inside
    /// `RenderGate`, same reasoning as `decode(contentsOf:)` above —
    /// `filter.nativeSize` alone forces RawCamera to parse the file's
    /// header, so even that read isn't free to leave ungated.
    /// RAW-native `EditState` fields (Phase 6 slices 2-4): so a RAW
    /// thumbnail matches the Editor's own rendering after an edit, same
    /// reasoning as every other `editState`-driven thumbnail parameter —
    /// see `ThumbnailGenerator`. `rawWhiteBalanceNeutralPoints` specifically
    /// measured live to be safe here despite draft mode/`scaleFactor`
    /// running AFTER it in this function (a different relative order than
    /// `decode` above, which has nothing after it to reorder against):
    /// `neutralLocation` set via `nativeSize`-relative coordinates, then
    /// draft mode + a 0.25 `scaleFactor` applied, produced the SAME
    /// `neutralTemperature`/`neutralTint` and the SAME neutralized pixel
    /// (sampled at the correspondingly-scaled position) as a full decode
    /// with no draft mode at all — `neutralLocation`'s coordinate space is
    /// relative to `nativeSize`, not the (possibly scaled) output extent,
    /// so draft mode doesn't perturb it.
    static func decodeDraft(contentsOf url: URL, maxPixelSize: Int, editState: EditState) async -> CIImage? {
        await RenderGate.shared.run {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            // Applied FIRST, immediately after construction — same position
            // as `decode` above. Reviewer-caught: an earlier draft applied
            // this AFTER `isDraftModeEnabled`/`scaleFactor` here but
            // immediately after `orientation` in `decode`, an unmeasured
            // ordering difference between the two functions for a
            // read-modify-write mechanic (`shadowBoostScale`'s `*=`) that
            // could plausibly diverge an edited RAW's Editor render from its
            // Library thumbnail — the exact defect class post-Phase-5
            // follow-up #4 already cost this app once. Keeping the position
            // identical removes the need to measure whether draft mode/
            // scaling perturbs `filter`'s pre-populated values at all.
            applyRawNativeSettings(editState, to: filter)
            if let orientation = readExifOrientation(of: url) {
                filter.orientation = orientation
            }
            filter.isDraftModeEnabled = true
            let longestSide = max(filter.nativeSize.width, filter.nativeSize.height)
            if maxPixelSize > 0, longestSide > 0 {
                // Clamped to 1 — `scaleFactor` only ever downsizes (Apple's
                // own header documents its valid range as 0...1); a
                // thumbnail request larger than the native image should
                // return the native size, not upscale.
                filter.scaleFactor = min(1, Float(CGFloat(maxPixelSize) / longestSide))
            }
            return filter.outputImage
        }
    }

    /// Applies every RAW-native `EditState` field to `filter`. This is the
    /// ONE place that reads them; `EditState.requiresRawRedecode` is the
    /// other place this exact field set is enumerated — keep both in
    /// sync.
    ///
    /// `boostAmount` and `rawExposureEV` are ABSOLUTE assignments to
    /// properties with fixed, camera-profile-independent defaults
    /// (`CIRAWFilter.exposure`'s own SDK header declares a fixed default
    /// of `0`; confirmed live it reads `0.0` on real Nikon D610 NEFs whose
    /// `baselineExposure` — a DIFFERENT property — reads `0.3`). An
    /// earlier draft of `rawExposureEV` mutated `baselineExposure` with
    /// `+=` instead, matching `shadowBoostScale`'s relative shape below —
    /// reviewer-caught and switched: `exposure` measured to combine with
    /// `baselineExposure` additively inside `CIRAWFilter` (setting
    /// `exposure = 2.0` and mutating `baselineExposure += 2.0` produced
    /// BYTE-IDENTICAL pixels on the same file), so it renders identically
    /// while being a plain absolute value — no read-modify-write, and no
    /// exception to this app's "replaying the same params must be
    /// deterministic" invariant.
    ///
    /// `shadowBoostScale` genuinely IS relative to `filter`'s own
    /// pre-populated `boostShadowAmount` (per-file, not the API's declared
    /// default of `1` — measured `0.9` on real D610 NEFs), so it reads
    /// `filter`'s current value first via `*=` rather than an absolute
    /// assignment. Guarded to only mutate when `shadowBoostScale != 1`
    /// (identity) — reviewer-caught: this makes "untouched photo decodes
    /// exactly as before" a STRUCTURAL guarantee (the property is never
    /// touched at all) rather than relying on `x *= 1` being a semantic
    /// no-op, which isn't guaranteed for an ObjC-bridged filter property
    /// that could plausibly flip an internal "user overrode this" flag on
    /// any write, regardless of the value written.
    ///
    /// `rawColorNoiseReductionScale`/`rawSharpnessScale` are the SAME
    /// relative shape as `shadowBoostScale` above, for the identical
    /// reason: their underlying `CIRAWFilter` properties
    /// (`colorNoiseReductionAmount`, `sharpnessAmount`) are per-file,
    /// camera-profile-seeded (measured `0.5`/`0.9` respectively on real
    /// D610 NEFs; the SDK header documents "the default value will vary
    /// per image" for each, same wording as `boostShadowAmount`'s own) —
    /// each reads `filter`'s current value first via `*=`, guarded to
    /// only mutate when `!= 1`, same structural-no-op reasoning as
    /// `shadowBoostScale`.
    ///
    /// `rawLuminanceNoiseReductionAdjust` is DIFFERENT — reviewer-caught:
    /// it was originally the same `*=` scale shape, but this camera's own
    /// native `luminanceNoiseReductionAmount` measures `0.0`, so `native
    /// * anything` is always `0` — a provably dead control across its
    /// ENTIRE range, not just a narrow inert band like
    /// `boostShadowAmount`'s upper half. Switched to an ADDITIVE offset
    /// (`filter.luminanceNoiseReductionAmount + adjust`, clamped to the
    /// property's own `0...1` range) — confirmed live that an absolute
    /// `1.0` assignment DOES move real pixels on this camera, so there is
    /// genuinely useful range above `0.0` an offset can reach that a
    /// scale never could. See `EditState.rawLuminanceNoiseReductionAdjust`'s
    /// own doc comment for the full reasoning.
    ///
    /// `rawWhiteBalanceNeutralPoints` seeds `filter.neutralLocation`
    /// directly, converting its stored normalized (0...1) fraction to
    /// absolute pixel coordinates via `filter.nativeSize` (available
    /// before `.outputImage` is ever accessed — no extra decode cost).
    /// UNLIKE every other field above, this one's correctness is NOT
    /// position-independent in general: measured live that
    /// `neutralLocation` produces a different result depending on
    /// whether `orientation` was already set to a non-`.up` value at the
    /// moment it's assigned. Safe to keep at this same "immediately after
    /// construction" position ONLY because
    /// `EditState.rawWhiteBalanceNeutralPoints`'s own doc comment
    /// guarantees this field is non-empty ONLY when the file's EXIF
    /// orientation was CONFIRMED `.up` at load time — so `orientation`
    /// below is always assigned the SAME value it already held (measured
    /// identical either order in that specific regime), not left
    /// genuinely untouched. Do not add another RAW-native POINT field
    /// without re-measuring this — it does not follow from the other
    /// six fields' own "position doesn't matter" precedent (all six are
    /// non-spatial scalars; the neutral point is the one genuinely
    /// spatial field here).
    ///
    /// All seven clamped defensively — matching `decodeDraft`'s existing
    /// `scaleFactor` clamp precedent — even though the Adjust-tab sliders
    /// (or, for the neutral point, `ImageDocumentModel.pickWhiteBalance`'s
    /// own eligibility gate) already constrain them. `boostShadowAmount`'s
    /// (and the two remaining scales') result needs no upper clamp —
    /// scaling a value already within `CIRAWFilter`'s own declared range
    /// by a factor in `0...1` cannot leave that range.
    ///
    /// UNLIKE `boostAmount`/`rawExposureEV`/`shadowBoostScale`, the three
    /// fields added in slice 5 DO have a real capability gate —
    /// reviewer-caught: an earlier draft of this comment claimed
    /// otherwise, but `isLuminanceNoiseReductionSupported`/
    /// `isColorNoiseReductionSupported`/`isSharpnessSupported` are
    /// structurally identical to `isLensCorrectionSupported` (the exact
    /// flag that killed slice 2's `lensCorrectionEnabled` candidate).
    /// Measured `true` for all three on this camera — this slice IS
    /// viable, not another dead end — but a different camera COULD
    /// measure `false`, and applying the value unconditionally would then
    /// be a silent no-op paying a full re-decode for nothing.
    /// `confirmedAdjustmentSupport(of:)` below reads all three flags,
    /// gated, once per RAW photo load; `ImageDocumentModel` caches the
    /// result and disables each of the three UI rows individually rather
    /// than gating the write here — applying the value is still safe
    /// even when unsupported (Core Image documents no crash, just no
    /// effect), so the gate only needs to prevent a MISLEADING always-
    /// enabled slider, not an unsafe write.
    private static func applyRawNativeSettings(_ editState: EditState, to filter: CIRAWFilter) {
        filter.boostAmount = Float(min(1, max(0, editState.boostAmount)))
        let ev = min(2, max(-2, editState.rawExposureEV))
        if ev != 0 {
            filter.exposure = Float(ev)
        }
        let shadowScale = min(1, max(0, editState.shadowBoostScale))
        if shadowScale != 1 {
            filter.boostShadowAmount *= Float(shadowScale)
        }
        let lumNRAdjust = min(1, max(-1, editState.rawLuminanceNoiseReductionAdjust))
        if lumNRAdjust != 0 {
            let combined = filter.luminanceNoiseReductionAmount + Float(lumNRAdjust)
            filter.luminanceNoiseReductionAmount = min(1, max(0, combined))
        }
        let colorNRScale = min(1, max(0, editState.rawColorNoiseReductionScale))
        if colorNRScale != 1 {
            filter.colorNoiseReductionAmount *= Float(colorNRScale)
        }
        let sharpnessScale = min(1, max(0, editState.rawSharpnessScale))
        if sharpnessScale != 1 {
            filter.sharpnessAmount *= Float(sharpnessScale)
        }
        if let point = editState.rawWhiteBalanceNeutralPoints.first,
           filter.nativeSize.width > 0, filter.nativeSize.height > 0 {
            let x = min(1, max(0, point.x))
            let y = min(1, max(0, point.y))
            // Clamped to `nativeSize - 1`, not `nativeSize` — a fraction
            // of exactly `1` would land one pixel PAST the last valid
            // column/row.
            filter.neutralLocation = CGPoint(
                x: x * (filter.nativeSize.width - 1),
                y: y * (filter.nativeSize.height - 1)
            )
        }
    }

    /// Renders `image` once into a realized pixel buffer and re-wraps it as
    /// a new `CIImage` backed by that buffer, instead of the original lazy
    /// filter graph.
    ///
    /// Live-caught real bug this exists to fix: a `CIImage` is a lazy
    /// RECIPE, not decoded pixels — `ImageRenderer.draw(in:)` runs
    /// `EditPipeline.apply` and re-renders on every redraw (every slider
    /// tweak), and for a plain `CIImage(contentsOf:)` source that's cheap
    /// to re-run (already-demosaiced pixels). For a RAW source, `image` is
    /// `CIRAWFilter`'s own lazy graph, so every one of those redraws
    /// silently re-ran the ENTIRE full-resolution RAW demosaic from
    /// scratch, synchronously, on the main thread — confirmed live via a
    /// hung `PhotoApp` process, `sample`d mid-freeze with virtually 100% of
    /// samples inside `ImageRenderer.draw(in:)` →
    /// `-[CIContext render:toMTLTexture:...]`, on a real 24MP Nikon D610
    /// NEF. This turns that into a ONE-TIME cost paid once when the photo
    /// loads (still a real, bounded pause — see `ImageDocumentModel.load(from:)`'s
    /// call site — but no longer repeated on every single interaction).
    ///
    /// Renders into `extendedLinearSRGB`/64-bit half-float
    /// (`kCVPixelFormatType_64RGBAHalf`), matching this app's working color
    /// space everywhere else that runs `EditPipeline`
    /// (`ImageRenderer`/`PhotoExporter`/`ThumbnailGenerator`/
    /// `WhiteBalanceSolver`) — deliberately NOT an 8-bit/sRGB intermediate,
    /// which would silently clip exactly the extended range/gamut RAW
    /// provides before any edit math ever saw it (the same defect class the
    /// reviewer caught in the thumbnail path during this same feature's
    /// review).
    ///
    /// Only meaningful — and only worth its own one-time cost — for RAW
    /// sources; callers are expected to have already checked `isRaw(url)`
    /// before calling this (mirrors `decodeDraft`'s own precondition).
    /// Falls back to returning `image` unchanged if the pixel buffer can't
    /// be created, so a failure here degrades back to the pre-fix (slow but
    /// correct) behavior rather than losing the image — reviewer-flagged:
    /// that fallback path escapes `RenderGate` entirely, since it returns
    /// before the gated render below ever runs. In practice unreachable
    /// (the extent/pixel-buffer checks above only fail on a malformed
    /// source), but worth knowing precisely if it ever does trigger:
    /// `ImageRenderer.draw(in:)` would then evaluate that still-lazy
    /// `CIRAWFilter` graph directly, per frame, on the main thread —
    /// degrading back to BOTH bugs this file exists to fix, not just one.
    ///
    /// Forward hazard for Phase 6 slice 2, PREDICTED here and CONFIRMED true
    /// when `boostAmount` shipped: once `CIRAWFilter`'s own native controls
    /// become `EditState` fields, changing them has NO EFFECT on an
    /// already-loaded photo — the pipeline input by then is this fixed,
    /// already-baked buffer, not the live `CIRAWFilter` graph those
    /// properties configure. Resolution shipped in
    /// `ImageDocumentModel.redecodeForRawNativeChange()` (debounced via
    /// `scheduleRawRedecode()`), triggered from `editState`'s own `didSet`
    /// via `EditState.requiresRawRedecode(comparedTo:)` — that re-decodes
    /// (not just re-materializes) on every change to a RAW-native field,
    /// unlike every other `EditState` field, which is cheap to re-run
    /// against this cached buffer via `EditPipeline` as today.
    static func materialize(_ image: CIImage) async -> CIImage {
        let extent = image.extent
        // `CGRect.infinite`'s width/height are `CGFloat.greatestFiniteMagnitude`
        // — genuinely FINITE by IEEE semantics, so an `.isFinite` check alone
        // does NOT catch it (a real bug caught by this file's own test: an
        // earlier version guarded with `.isFinite` only, and converting
        // `greatestFiniteMagnitude` to `Int` below trapped at runtime rather
        // than falling back gracefully). `.isInfinite` is `CGRect`'s own
        // correct check for this; the explicit upper bound additionally
        // guards any other implausibly large extent from overflowing `Int`.
        guard !extent.isInfinite, !extent.isNull,
              extent.width > 0, extent.height > 0,
              extent.width < CGFloat(Int32.max), extent.height < CGFloat(Int32.max)
        else {
            return image
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(extent.width.rounded()),
            Int(extent.height.rounded()),
            kCVPixelFormatType_64RGBAHalf,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return image }
        // `CVPixelBuffer` isn't (yet) audited `Sendable` by CoreVideo, even
        // though crossing this actor boundary with it is safe here — this
        // function owns the only reference until `run`'s closure returns,
        // nothing else touches it concurrently.
        let pixelBufferBox = UncheckedSendableBox(value: pixelBuffer)
        // Routed through `RenderGate` (see its own doc comment) — this is
        // exactly the render call that deadlocked against concurrent
        // Library-grid RAW thumbnail decoding when it ran unserialized.
        await RenderGate.shared.run {
            materializeContext.render(
                image, to: pixelBufferBox.value, bounds: extent, colorSpace: materializeColorSpace
            )
            // `materializeContext` is a long-lived static context — without
            // this, its internal intermediate caches would hold onto this
            // full-res RAW render's working buffers indefinitely, on top of
            // the `CVPixelBuffer` this function already returns and callers
            // own.
            materializeContext.clearCaches()
        }
        // A CVPixelBuffer-backed CIImage always has its extent origin at
        // (0, 0); translate back to the source's own origin so callers see
        // the identical extent they passed in (a no-op in the common case —
        // every `CIRAWFilter.outputImage` measured live already had
        // origin (0, 0) — but correct in general rather than assumed).
        return CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: materializeColorSpace])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// Not `private`: `RawDecoderTests` needs this to construct an
    /// out-of-`[0,1]`-range test color IN this exact working space, so the
    /// materialize round-trip test actually exercises extended range rather
    /// than silently passing on inputs an 8-bit intermediate would also
    /// preserve (reviewer-caught — see that test's own doc comment).
    static let materializeColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private static let materializeContext = CIContext(options: [
        .workingColorSpace: materializeColorSpace,
        .workingFormat: CIFormat.RGBAh
    ])
}
