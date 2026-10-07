import CoreImage

/// Renders the small previews for the Looks tab's thumbnail grid: `EditPipeline.apply` on ONE small realized copy of the open
/// photo, flattened to an 8-bit sRGB `CGImage`. Same pipeline as the live editor, only smaller — so previews are approximate for
/// stages whose look depends on image size (Clarity, Dehaze, Noise Reduction, Grain, Glow); the click result is always the real
/// render. Nothing here is UI: callers pick the cells (`LookPreviewItem`) and the state (`LookPreviewItem.previewState`).
enum LookPreviewRenderer {
    /// Long side of the shared base image, in pixels (a cell is ~100 pt wide; 160 px keeps it sharp on a 2x display).
    static let baseLongSide: CGFloat = 160

    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Same working space as every other `EditPipeline` caller (`ThumbnailGenerator`, `ProxyBuilder`).
    private static let context = CIContext(options: [.workingColorSpace: workingColorSpace, .workingFormat: CIFormat.RGBAh])

    /// ONE small realized base for the photo: the lazy full-resolution source would be re-decoded by every preview render.
    /// Rebuild it whenever `currentImage` is replaced — a new photo, or a RAW re-decode, whose RAW-native fields are baked into
    /// pixels that `EditPipeline.apply` never touches. Built by `ProxyBuilder.build` (Lanczos into a realized extended-linear
    /// half-float buffer); nil for a degenerate image — including an extreme aspect ratio whose short side would scale below one pixel (a 1x4000 strip gets no previews; callers retry cheaply and harmlessly).
    static func makeBase(from image: CIImage, longSide: CGFloat = baseLongSide) async -> CIImage? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0, longSide.isFinite, longSide > 0 else { return nil }
        let scale = min(1, longSide / max(extent.width, extent.height))
        return await ProxyBuilder.build(image, scale: scale)
    }

    /// Drops the static context's cached intermediates (colour cubes, decoded mask rasters). Call after a full grid pass, like
    /// `ProxyBuilder` does after a build — not per cell.
    static func releaseCaches() { context.clearCaches() }

    /// The pipeline output for `state` on `base`, as an sRGB 8-bit image of the output's own pixel size (the state's crop and
    /// straighten apply, so the preview has the framing the user sees). nil if the output extent is unusable. Synchronous and
    /// CPU/GPU bound: call it off the main thread.
    static func render(_ state: EditState, base: CIImage) -> CGImage? {
        let output = EditPipeline.apply(state, to: base)
        let extent = output.extent.integral
        guard !extent.isInfinite, !extent.isNull, extent.width >= 1, extent.height >= 1,
              extent.width <= 4096, extent.height <= 4096 else { return nil }
        let width = Int(extent.width), height = Int(extent.height)
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: rowBytes, bounds: extent, format: .RGBA8, colorSpace: outputColorSpace)
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: outputColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }
}
