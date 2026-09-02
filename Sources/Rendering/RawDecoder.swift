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
/// Phase 6 slice 1 scope: decode only. `CIRAWFilter`'s own RAW-native
/// controls (`baselineExposure`, `boostAmount`, `neutralTemperature`/
/// `neutralLocation`, `lensCorrectionEnabled`, its NR/sharpness/detail/moiré
/// sliders) are a genuine `EditState`-level feature deferred to a later
/// session — see CLAUDE.md/PROGRESS.md.
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
    static func decode(contentsOf url: URL) async -> CIImage? {
        guard isRaw(url) else {
            return CIImage(contentsOf: url)?.oriented(exifOrientation(of: url))
        }
        return await RenderGate.shared.run {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
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
    static func decodeDraft(contentsOf url: URL, maxPixelSize: Int) async -> CIImage? {
        await RenderGate.shared.run {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
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
    /// Forward hazard for Phase 6 slice 2 (reviewer-flagged): once
    /// `CIRAWFilter`'s own native controls (`baselineExposure`,
    /// `boostAmount`, `neutralTemperature`, etc.) become `EditState`
    /// fields, changing them will have NO EFFECT on an already-loaded
    /// photo — the pipeline input by then is this fixed, already-baked
    /// buffer, not the live `CIRAWFilter` graph those properties configure.
    /// Whatever wires those controls up will need to re-decode (not just
    /// re-materialize) on every change to that specific field group, unlike
    /// every other `EditState` field, which is cheap to re-run against this
    /// cached buffer via `EditPipeline` as today.
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
