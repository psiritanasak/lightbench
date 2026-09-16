import CoreImage
import MetalKit

/// Renders a `CIImage` into an `MTKView`'s drawable, aspect-fit and centered.
///
/// `draw(in:)` is only ever invoked by MetalKit on the main thread (the view
/// is configured with `isPaused = true` / `enableSetNeedsDisplay = true`, so
/// there is no internal render loop), and `image` is only ever written from
/// `MetalImageView.updateNSView`, which SwiftUI also calls on the main actor.
/// Marking the type `@MainActor` makes that contract explicit instead of implicit.
@MainActor
final class ImageRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    /// Core Image performs all filter math (via `EditPipeline`) in this
    /// explicitly-defined linear working space (extended-range linear sRGB,
    /// 16-bit half-float to match the view's `.rgba16Float` drawable). This
    /// satisfies CLAUDE.md's "all image math in linear light in a defined
    /// working color space" — the space is defined here rather than relying
    /// on CIContext's defaults. Extended range preserves highlight/shadow
    /// headroom created by adjustments like exposure. Conversion to display
    /// sRGB happens only at final render, via `outputColorSpace` below (the
    /// "output transform" stage of the fixed pipeline).
    private let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        ?? CGColorSpace(name: CGColorSpace.linearSRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    /// Not `private`: `MetalImageView.makeNSView` tags the presenting
    /// `CAMetalLayer` with this SAME instance, so the drawable's declared
    /// color space can never drift from what `render(...)` below actually
    /// encodes into. Without that layer tag, CoreAnimation doesn't know
    /// this `.rgba16Float` drawable's sRGB-gamma-encoded values are sRGB
    /// (float formats have no `_sRGB` pixel-format variant to imply it),
    /// so it under-decodes them on display — a real, live-verified bug:
    /// the Editor rendered visibly brighter/less saturated than the same
    /// file in Preview.app or this app's own (correctly-tagged) exported
    /// files, despite identical working/output color-space math in both
    /// paths.
    let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    var image: CIImage?
    var editState: EditState = .identity
    /// Non-nil enables the Compare feature (Side by Side / Split);
    /// `nil` is the default, single-image path — see `draw(in:)`.
    var compare: CompareRenderConfig?
    /// 1 = fit (no zoom), up to `ZoomPanGeometry.maxZoom`. Applied via
    /// `fitted(_:into:zoomScale:panOffsetNorm:)`, on top of every render
    /// path (off/sideBySide/split) uniformly.
    var zoomScale: CGFloat = 1
    /// Fit-rect-normalized, SwiftUI y-DOWN (see `fitted(_:into:zoomScale:
    /// panOffsetNorm:)`'s own doc comment for where/why this gets flipped
    /// to this renderer's y-UP space).
    var panOffset: CGSize = .zero

    // MARK: - P3 pipeline-output cache (IMPROVEMENTS.md)
    //
    // `edited`/`original` are pure functions of (source `image`, some
    // `EditState`) — see `EditPipeline.apply`'s own signature. Caching them
    // here means a redraw triggered ONLY by resize/zoom/pan/Compare-divider-
    // drag (none of which touch `image` or any `EditState`) reuses the
    // existing `CIImage` graphs instead of rebuilding the whole ~12-stage
    // pipeline every frame. Self-invalidating and self-contained inside
    // `draw(in:)` — does NOT depend on `MetalImageView.updateNSView` having
    // run first, because a resize redraw (`ResizingMTKView.setFrameSize`)
    // reaches `draw(in:)` directly without going through `updateNSView` at
    // all. Measured live (IMPROVEMENTS.md P3): most frames were already
    // sub-millisecond, but real spikes up to ~459ms appeared during a
    // resize/zoom/pan sequence with Sharpen+NR+Clarity active and
    // nothing else changing — this cache eliminates exactly that redundant
    // rebuild.
    private var cachedSourceImage: CIImage?
    private var cachedEditState: EditState?
    private var cachedEdited: CIImage?
    private var cachedOriginalState: EditState?
    private var cachedOriginal: CIImage?

    // MARK: - P2 interactive proxy (IMPROVEMENTS.md)
    //
    // While a sustained slider drag is in progress, `edited`/`original`
    // above are built from a downscaled PROXY of `image` instead of the
    // full-resolution source, then a real full-resolution frame renders
    // once the drag settles (~0.25s of no further `editState` change).
    // Justified by live measurement: a continuous Sharpen drag with
    // Sharpen+NoiseReduction+Clarity active on a large photo showed
    // `draw(in:)` frames frequently at 19-42ms with outliers at 184.7ms
    // and 279.0ms — the P3 cache above does NOT help this case, since
    // `editState` changes every frame of a drag, a guaranteed cache miss.
    //
    // Preview-vs-final divergence this trades in. Listed in no particular
    // severity order: measured rank swaps with both proxy scale and image
    // content (IMPROVEMENTS.md D18), so a fixed ordering would misinform.
    //   - Noise Reduction: `CINoiseReduction.noiseLevel` is a per-pixel
    //     threshold, measured resolution-INDEPENDENT with deliberately no
    //     extent term (see `EditPipeline`'s `kNoiseReductionSpan` doc
    //     comment) — downscaling itself already averages away some noise
    //     before NR runs, so the interactive preview looks CLEANER than
    //     the settled frame and the export.
    //   - Dehaze: the largest divergence measured, at every scale on
    //     photo-like content. On a pixel-noise fixture Noise Reduction
    //     exceeds it at 0.5 — rank swaps with both scale and content, so no
    //     stage is "the worst" unconditionally. Two mechanisms: its
    //     morphology radius quantizes the way Sharpen's, Clarity's and
    //     Texture's do, AND its atmospheric light is a whole-frame statistic
    //     the proxy estimates from different pixels entirely.
    //     See IMPROVEMENTS.md D18 for the measured matrix.
    //   - Sharpen / Clarity / Texture: radii are extent FRACTIONS, so the
    //     on-screen halo is right at fit zoom, but the absolute pixel
    //     radius quantizes differently on a downscaled image.
    //   - Red-eye at aggressive proxy scales: radius is a fraction of
    //     `min(extent)`, so a pupil circle gets fewer pixels — least
    //     severe, only visible on an already-small image at a low
    //     required scale.
    //   - Lanczos's negative lobes (`ProxyBuilder`) can put slightly
    //     out-of-[0,1] linear values into the proxy at high-contrast edges
    //     that a decoded 8-bit source never has. Harmless in practice —
    //     `applyLevels` clamps before `CIGammaAdjust` runs — but a real,
    //     if minor, extra divergence source.
    // Every other stage (crop, straighten, perspective, flip, vignette,
    // WB, exposure, levels, curves, HSL, saturation, B&W) is exactly
    // extent-proportional or purely per-pixel, so a proxy renders
    // identically to full-res for those, up to resampling — see
    // `ProxyScale`'s own doc comment for the fuller argument. Scope note:
    // NONE of those were included in D18's measurements, which covered only
    // dehaze/NR/sharpen/clarity. This paragraph is the original reasoning,
    // not a measured result; do not read D18 as having confirmed OR refuted
    // it.
    //
    // Interaction is detected purely by COUNTING consecutive `editState`
    // changes (`ProxyInteraction`), not by timing between them — `draw(in:)`
    // is synchronous, so timestamps would be inflated by exactly the slow
    // frames this feature exists to fix. `isInteracting` only goes true on
    // the 2nd+ change in a burst, so a single discrete change (undo/redo, a
    // typed value, a toggle, a preset) always renders full-res immediately.
    //
    // Structural invariant that makes this safe to reason about: the proxy
    // `CIImage` never escapes `ImageRenderer` — it's held by `cachedProxy`
    // and (transitively, via the graphs rooted on it) `cachedPipelineSource`/
    // `cachedEdited`/`cachedOriginal`, all four cleared together the moment
    // the source `image` changes (see `draw(in:)`), and never assigned to
    // `image` itself. Every other render path in this app (overlay fit
    // rects in `ContentView`, the histogram, `ThumbnailGenerator`,
    // `PhotoExporter`, `WhiteBalanceSolver`) reads `image`/`currentImage`
    // directly and is structurally unreachable from the proxy.
    private var interaction = ProxyInteraction()
    private var lastDrawnEditState: EditState?
    private weak var lastDrawnView: MTKView?
    private var settleWorkItem: DispatchWorkItem?
    private static let settleInterval: TimeInterval = 0.25 // feel, not measured —
        // between the histogram debounce (0.15s) and the history coalesce
        // debounce (0.35s), both in ImageDocumentModel.

    private var cachedProxy: CIImage?
    private var cachedProxyScale: CGFloat?
    private var proxyBuildGeneration = 0
    private var proxyBuildInFlight = false

    /// Which of `image`/`cachedProxy` actually produced the current
    /// `cachedEdited`/`cachedOriginal` — a SECOND, independent cache key
    /// layered on top of the `cachedSourceImage` check above, not a
    /// replacement for it. `cachedSourceImage`'s check is unconditional
    /// (any new source image drops everything); this one additionally
    /// catches the proxy transition mid-photo. Both must clear the SAME
    /// two output slots together: today, `compare.originalState` doesn't
    /// change during a slider drag, so without this, `cachedOriginal`
    /// would hit and hand back a FULL-RES original composited against a
    /// PROXY-derived `cachedEdited` — a sharpness mismatch right at the
    /// Split divider, the one place the user is looking. Since Compare's
    /// `original` and `edited` are always built from the SAME resolved
    /// input within one `draw(in:)` call, Compare gets the proxy for BOTH
    /// halves for free from this single key — costing nothing in quality,
    /// since `EditState.comparisonOriginal()` already zeroes
    /// `clarity`/`texture`/`dehaze`/`sharpness`/`noiseReduction`, so the
    /// original half has no PROXY-DIVERGENT stage left to diverge in the first
    /// place. (Not "no convolution stage" — Dehaze is not a convolution, and
    /// its dominant divergence mechanism is a whole-frame statistic, not a
    /// radius. It belongs in this list for the divergence, not the filter
    /// shape.)
    private var cachedPipelineSource: CIImage?

    init(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else {
            fatalError("Metal device failed to create a command queue")
        }
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingColorSpace,
            .workingFormat: CIFormat.RGBAh
        ])
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Scales/translates `image` to occupy exactly `fitRect` — the SAME
    /// arithmetic `draw(in:)` always used inline, extracted (not
    /// rewritten) so the Compare feature's extra fitted images go through
    /// the identical math as the single-image path, byte for byte. See
    /// `draw(in:)`'s own comment for why there's deliberately no y-flip
    /// here.
    ///
    /// `zoomScale`/`panOffsetNorm` are optional (default to 1/`.zero`, an
    /// exact no-op — every existing call reusing these defaults renders
    /// byte-identically to before zoom/pan existed). When active: the
    /// scaled content is centered on `fitRect`'s own center (so zooming
    /// about the middle needs no pan) and then shifted by `panOffsetNorm`
    /// — fit-rect-normalized fractions in SwiftUI's y-DOWN convention
    /// (`ZoomPanGeometry`'s convention throughout). This renderer's own
    /// space is y-UP (visual bottom at low y — the same "no y-flip"
    /// finding `draw(in:)` documents), the OPPOSITE of SwiftUI's for the
    /// y axis specifically — exactly the asymmetry Compare's horizontal
    /// split already had to get right — so `panY` is negated here and
    /// ONLY here; every other zoom/pan call site (state storage, the
    /// gesture, `ZoomPanGeometry`) stays uniformly y-DOWN and never has
    /// to reason about this.
    private func fitted(
        _ image: CIImage, into fitRect: CGRect, zoomScale: CGFloat = 1, panOffsetNorm: CGSize = .zero
    ) -> CIImage {
        let scale = (fitRect.width / image.extent.width) * zoomScale
        let panX = panOffsetNorm.width * fitRect.width
        let panY = -panOffsetNorm.height * fitRect.height
        let zoomedMinX = fitRect.midX - fitRect.width * zoomScale / 2 + panX
        let zoomedMinY = fitRect.midY - fitRect.height * zoomScale / 2 + panY
        let transform = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: zoomedMinX, y: zoomedMinY))
        return image.transformed(by: transform)
    }

    /// Cancels and re-arms the trailing-edge silence timer on EVERY
    /// observed `editState` change (not only the first) — same idiom as
    /// all four debounces in `ImageDocumentModel` (`cancel()` → new
    /// `DispatchWorkItem` → `DispatchQueue.main.asyncAfter`), including the
    /// "clear the work-item reference first inside the closure" trick from
    /// `scheduleSidecarSave()`. `interaction.settle()`'s own return value
    /// gates the redraw so a burst that never actually used the proxy
    /// doesn't pay one extra full-res redraw after every drag — reading
    /// `lastDrawnView` at FIRE time (not capturing the parameter) so this
    /// stays correct even if the view were ever replaced mid-drag.
    private func scheduleSettleRedraw() {
        settleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWorkItem = nil
            let needsRedraw = self.interaction.settle()
            if needsRedraw, let view = self.lastDrawnView {
                view.setNeedsDisplay(view.bounds)
            }
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleInterval, execute: workItem)
    }

    /// Kicks off an ASYNC proxy build — never synchronous inside `draw(in:)`.
    /// A synchronous materialize would hold `view.currentDrawable` and an
    /// open `MTLCommandBuffer` across a tens-of-ms Core Image render on the
    /// very first interactive frame after a photo loads, a stall the user
    /// would feel as "the slider sticks when I first grab it." Building
    /// asynchronously means the first few frames of a fresh burst render
    /// full-res (no worse than today), the proxy lands a build later, and
    /// every subsequent frame in that burst — and every later burst, since
    /// the proxy is cached per photo — is fast. Mirrors
    /// `ImageDocumentModel.redecodeForRawNativeChange`'s own
    /// generation-token pattern: `proxyBuildGeneration` is bumped whenever
    /// the source image changes (see `draw(in:)`), so a build that
    /// completes after the photo has already changed is silently dropped
    /// rather than installing the WRONG photo's proxy.
    ///
    /// AT MOST ONE build in flight at a time — reviewer-caught: an earlier
    /// version also allowed starting a NEW build whenever the newly
    /// required scale exceeded the in-flight target, meant to chase a
    /// growing requirement mid-burst. `requiredScale` grows monotonically
    /// across many frames of a real burst (e.g. dragging Straighten back
    /// toward 0° shrinks the extent every frame, raising `fitScale`), so
    /// that clause spawned a build on every such frame — reviewer-derived
    /// (from the geometry, not instrumented on a live drag): tens of
    /// concurrent builds for one drag, each holding its own ~80MB
    /// `CVPixelBuffer` before even reaching `RenderGate`, all serialized
    /// behind that same app-wide RAW gate (stalling RAW thumbnail/re-decode
    /// work for seconds), with no guaranteed completion order so a
    /// smaller-scale build finishing last could overwrite a better one and
    /// trigger yet another rebuild. A single in-flight guard is simpler and
    /// strictly better: frames just keep using the still-loading (slightly
    /// too small) `cachedProxy` — exactly what they already do while ANY
    /// build is pending — and `canReuse` naturally re-requests once, on the
    /// next frame after the current build completes.
    private func requestProxyBuild(from image: CIImage, scale: CGFloat) {
        guard !proxyBuildInFlight else { return }
        let generation = proxyBuildGeneration
        proxyBuildInFlight = true
        Task { [weak self] in
            let built = await ProxyBuilder.build(image, scale: scale)
            guard let self, generation == self.proxyBuildGeneration else { return }
            self.proxyBuildInFlight = false
            if let built {
                self.cachedProxy = built
                self.cachedProxyScale = scale
                if let view = self.lastDrawnView {
                    view.setNeedsDisplay(view.bounds)
                }
            }
        }
    }

    /// Returns the `CIImage` the pipeline should actually run against this
    /// frame: `image` itself unless a sustained drag is in progress AND
    /// downscaling is worthwhile at the current display size/zoom.
    ///
    /// The required scale is computed via an EXACT probe —
    /// `EditPipeline.apply(editState, to: image).extent.size` — rather than
    /// estimating the post-crop extent from `EditState`'s crop insets
    /// directly. This IS run on every interacting frame (it's the input to
    /// `ProxyScale.canReuse` just below, so it can't be skipped), but it's
    /// cheap regardless: `ContentView`'s own overlay-fit-rect code already
    /// establishes that building the pipeline graph just to read `.extent`
    /// renders no pixels — sub-millisecond graph allocation against the
    /// 19-42ms frames this feature targets. Worth paying for what it buys:
    /// an EXACT answer, correct for crop, straighten's extent growth, and
    /// perspective automatically, instead of needing its own copy of
    /// `EditPipeline`'s private crop-inset clamp to estimate it.
    private func choosePipelineSource(image: CIImage, drawableSize: CGSize) -> CIImage {
        guard interaction.isInteracting else { return image }

        let isSideBySide = compare?.mode == .sideBySide
        let container = ProxyScale.effectiveContainer(drawableSize: drawableSize, isSideBySide: isSideBySide)
        let displayedExtentSize = EditPipeline.apply(editState, to: image).extent.size
        let sourcePixelCount = image.extent.width * image.extent.height

        guard let requiredScale = ProxyScale.requiredScale(
            displayedExtentSize: displayedExtentSize, container: container, zoomScale: zoomScale
        ), ProxyScale.isWorthwhile(requiredScale: requiredScale, sourcePixelCount: sourcePixelCount) else {
            return image
        }

        if !ProxyScale.canReuse(cachedScale: cachedProxyScale, requiredScale: requiredScale) {
            requestProxyBuild(from: image, scale: requiredScale)
        }
        return cachedProxy ?? image
    }

    func draw(in view: MTKView) {
        guard let image,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        lastDrawnView = view

        // P2 interaction detection: purely a COUNT of consecutive `editState`
        // changes across draws, re-arming the settle timer on every one —
        // see `ProxyInteraction`'s own doc comment for why this is timing-
        // independent by construction. Order matters: compare BEFORE
        // overwriting `lastDrawnEditState`, or the settle draw itself (which
        // changes nothing) would spuriously look like a new change and
        // re-arm forever.
        if editState != lastDrawnEditState {
            interaction.noteEditStateChanged()
            scheduleSettleRedraw()
        }
        lastDrawnEditState = editState

        // MARK: - Edit pipeline
        // Any true source-image change (a new photo loaded, or RAW
        // re-decode swapping `currentImage`) invalidates BOTH cached
        // outputs AND the P2 proxy state — they were all built from the OLD
        // image. `!==` matches `MetalImageView.updateNSView`'s own identity
        // comparison; `currentImage` is only ever reassigned wholesale,
        // never mutated in place. This check is UNCONDITIONAL and stays
        // that way even with the proxy in play below: it's the safety net
        // that guarantees a stale proxy from a previous photo can never
        // survive a real photo change, independent of whatever the proxy-
        // selection logic below does.
        if image !== cachedSourceImage {
            cachedSourceImage = image
            cachedProxy = nil
            cachedProxyScale = nil
            proxyBuildGeneration += 1
            proxyBuildInFlight = false
            interaction.reset()
            settleWorkItem?.cancel()
            settleWorkItem = nil
            cachedPipelineSource = nil
            cachedEditState = nil
            cachedEdited = nil
            cachedOriginalState = nil
            cachedOriginal = nil
        }

        let drawableSize = view.drawableSize
        let pipelineSource = choosePipelineSource(image: image, drawableSize: drawableSize)
        interaction.recordFrame(usedProxy: pipelineSource !== image)

        // A SECOND, independent invalidation for the resolved pipeline
        // input — see `cachedPipelineSource`'s own doc comment for why this
        // is additive, not a replacement for the `image` check above.
        if pipelineSource !== cachedPipelineSource {
            cachedPipelineSource = pipelineSource
            cachedEditState = nil
            cachedEdited = nil
            cachedOriginalState = nil
            cachedOriginal = nil
        }

        let edited: CIImage
        if let cachedEditState, cachedEditState == editState, let hit = cachedEdited {
            edited = hit
        } else {
            edited = EditPipeline.apply(editState, to: pipelineSource)
            cachedEditState = editState
            cachedEdited = edited
        }

        // Fit/transform against `edited.extent`, not `image.extent`: exposure
        // doesn't change extent so this is a no-op today, but the future crop
        // stage will change extent, so this must stay `edited` — don't
        // "simplify" it back to `image`.

        // No manual y-flip anywhere in this file. Empirically verified against
        // this exact live on-screen MTKView (colorPixelFormat = .rgba16Float,
        // framebufferOnly = false — see MetalImageView.swift) with a real photo
        // (EXIF orientation 1/identity): adding a y-flip made the on-screen
        // result appear rotated 180°; removing it displays correctly. The exact
        // mechanism isn't fully understood — an earlier version added the flip
        // because it tested "correct" against an offline, manually-created
        // MTLTexture read back on the CPU, so something about that offscreen
        // setup doesn't faithfully reproduce this live drawable's behavior. Do
        // NOT assume "no flip" holds for other destinations or configs — in
        // particular, Phase 5 batch export and Phase 7 tiled rendering render to
        // offscreen/standalone MTLTextures (the same shape of destination that
        // misled the earlier test), so those paths were independently
        // re-derived and verified, not assumed identical to this. The Compare
        // feature's horizontal-split orientation has the SAME open question —
        // which drawable-space half is visually "top" — and MUST be verified
        // live on a real photo (see `splitRects`' call site below), not
        // assumed from the geometry alone.

        // Composite over an explicit full-bounds black background before
        // rendering. Without this, CIContext.render only guarantees pixels
        // within the fitted image's own footprint — before crop existed, the
        // fitted image always touched at least one full edge of the
        // drawable (AspectFit always scales to fill one dimension), so the
        // untouched-margin case was never really exercised. Crop is the
        // first stage that can shrink the fitted image well below the
        // drawable's size on BOTH axes at once (e.g. a narrow, tall crop
        // fit into a wide window), leaving large margins. MTKView cycles
        // through multiple buffered drawable textures across frames; without
        // this explicit clear, dragging a crop slider left stale content
        // from earlier frames visible in those margins (looked like tiled/
        // repeated copies of the image) because each buffer in rotation
        // only ever had its own footprint overwritten, never the margins
        // around it.
        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: drawableSize))

        let composited: CIImage
        if let compare {
            // `original`'s geometry (crop/straighten/perspective/flip) is
            // identical to `edited`'s by construction — `comparisonOriginal()`
            // only resets color/tone fields — so `original.extent ==
            // edited.extent` always holds, and both sides can share ONE
            // `fitRect`/`AspectFit` computation below. Built from
            // `pipelineSource`, NOT `image` directly — during a proxied
            // drag this means Compare gets the proxy for BOTH halves, which
            // is what keeps them at matching sharpness (see
            // `cachedPipelineSource`'s own doc comment).
            let original: CIImage
            if let cachedOriginalState, cachedOriginalState == compare.originalState, let hit = cachedOriginal {
                original = hit
            } else {
                original = EditPipeline.apply(compare.originalState, to: pipelineSource)
                cachedOriginalState = compare.originalState
                cachedOriginal = original
            }
            switch compare.mode {
            case .sideBySide:
                let (leftRect, rightRect) = CompareLayout.sideBySideFitRects(
                    imageSize: edited.extent.size, drawableSize: drawableSize
                )
                guard leftRect.width > 0, leftRect.height > 0 else { return }
                // Original on the left, edited on the right — fixed layout,
                // matching the confirmed design (no orientation choice for
                // Side by Side).
                // SAME zoomScale/panOffset into both halves: since pan is
                // normalized to each (congruent) rect's own dimensions,
                // this alone keeps both sides showing the identical
                // relative detail through any zoom/pan — the "same detail
                // on both sides" sync this feature needs, with no extra
                // code beyond passing the same two values twice.
                //
                // `.cropped(to:)` each side to its OWN half is required
                // once zoom is in play — a real, live-caught bug: at
                // zoomScale == 1 the fitted image exactly fills its half,
                // so cropping was a no-op and easy to omit; but zoomed
                // past 1 the fitted image is LARGER than its half-rect and
                // bleeds into the neighboring half, where it sits on TOP
                // (composited first) and visually covers that side
                // entirely — looked like "one side enlarges and takes over
                // the other."
                let fittedOriginal = fitted(original, into: leftRect, zoomScale: zoomScale, panOffsetNorm: panOffset)
                    .cropped(to: leftRect)
                let fittedEdited = fitted(edited, into: rightRect, zoomScale: zoomScale, panOffsetNorm: panOffset)
                    .cropped(to: rightRect)
                composited = fittedOriginal.composited(over: fittedEdited.composited(over: background))
            case .split(let orientation, let position):
                let fitRect = AspectFit.rect(fitting: edited.extent.size, in: drawableSize)
                guard fitRect.width > 0, fitRect.height > 0 else { return }
                // Zoom/pan applied to BOTH fitted images identically; the
                // divider's own `originalRegion` below is computed from
                // the UN-zoomed `fitRect`, so the seam stays fixed on
                // screen while the content zooms/pans underneath it —
                // exactly matching how the divider's screen position is
                // independent of zoom in every other mode too.
                //
                // `.cropped(to: fitRect)` on `fittedEdited` is required once
                // zoom is in play — a real, live-caught bug, the same class
                // Side by Side already had to fix above: `fitted(_:into:
                // zoomScale:panOffsetNorm:)`'s own output extent matches
                // `fitRect` at zoomScale 1 (rendered output measured
                // byte-identical with or without this crop there — some
                // combinations differ from `fitRect` by sub-ulp float
                // rounding, but never enough to survive pixel-grid
                // rasterization, so the omission was invisible), but
                // strictly LARGER than `fitRect` past 1x — without this
                // crop, that overhang was visible in the letterbox margin
                // band around the image, including the band adjacent to the
                // ORIGINAL side of the divider, looking like edited content
                // mixed into the original. `fittedOriginal`'s own crop to
                // `originalRegion` (already a sub-rect of `fitRect`) needed
                // no change — only `fittedEdited` was ever unbounded.
                let fittedEdited = fitted(edited, into: fitRect, zoomScale: zoomScale, panOffsetNorm: panOffset)
                    .cropped(to: fitRect)
                let fittedOriginal = fitted(original, into: fitRect, zoomScale: zoomScale, panOffsetNorm: panOffset)
                // `CompareDividerOverlay` measures `position` in SwiftUI's
                // top-down space (0 = visual top, matching `fitRect.minY`
                // there). THIS fitRect is in Core Image's bottom-up space,
                // where `minY` is the visual BOTTOM — the same convention
                // this file's documented "no y-flip" finding establishes —
                // the OPPOSITE of the overlay's, for the y axis specifically.
                // The x axis has no such inversion (confirmed live: Side by
                // Side's fixed left/right layout matches expectations with
                // no adjustment). So for `.vertical`, `position`/`.first`
                // are used as-is; for `.horizontal`, the position fed into
                // `splitRects` is inverted, and `.second` (not `.first`) is
                // what actually lands in the visually-above-the-line region
                // the overlay draws — MEASURED LIVE, not assumed: the
                // pre-fix version put the rendered seam nowhere near the
                // drawn line, and dragging moved the edited region in the
                // visually opposite direction from the cursor.
                let originalRegion: CGRect
                switch orientation {
                case .vertical:
                    originalRegion = CompareLayout.splitRects(fitRect, orientation: .vertical, position: position).first
                case .horizontal:
                    originalRegion = CompareLayout.splitRects(fitRect, orientation: .horizontal, position: 1 - position).second
                }
                composited = fittedOriginal.cropped(to: originalRegion)
                    .composited(over: fittedEdited.composited(over: background))
            }
        } else {
            let fitRect = AspectFit.rect(fitting: edited.extent.size, in: drawableSize)
            guard fitRect.width > 0, fitRect.height > 0 else { return }
            composited = fitted(edited, into: fitRect, zoomScale: zoomScale, panOffsetNorm: panOffset)
                .composited(over: background)
        }

        ciContext.render(
            composited,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: drawableSize),
            colorSpace: outputColorSpace
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
