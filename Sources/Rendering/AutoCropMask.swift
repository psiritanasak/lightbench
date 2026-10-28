import CoreImage

/// Measures where the photo's geometry leaves transparent (revealed) pixels, from the REAL pipeline's alpha: Core Image pads the
/// straighten / perspective extent, so no analytic formula is exact. Runs `EditPipeline.apply` with the geometry fields only (crop
/// zeroed) on a small realized proxy; geometry stages scale proportionally with the source (`EditPipelineTests`'
/// `testGeometryStagesScaleProportionallyOnADownscaledSource`), so insets in fractions of the output frame carry to full resolution.
enum AutoCropMaskRenderer {
    /// Long side of the measuring proxy, in pixels.
    static let proxyLongSide: CGFloat = 800
    /// Alpha above this counts as opaque (an anti-aliased edge pixel is below it).
    static let opaqueThreshold: Double = 0.99

    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB(),
        .workingFormat: CIFormat.RGBAh])

    /// The state used for measuring: `state`'s geometry, no crop.
    static func measuringState(for state: EditState) -> EditState {
        var s = state.geometryOnlySamplingState()
        s.cropInsetTop = 0; s.cropInsetBottom = 0; s.cropInsetLeft = 0; s.cropInsetRight = 0
        return s
    }

    static func measure(image: CIImage, state: EditState, longSide: CGFloat = proxyLongSide) async -> AutoCropMask? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, longSide / max(extent.width, extent.height))
        guard let proxy = await ProxyBuilder.build(image, scale: scale) else { return nil }
        return mask(of: EditPipeline.apply(measuringState(for: state), to: proxy))
    }

    /// Alpha raster of an already-rendered pipeline output (row 0 = top). Synchronous and GPU bound.
    static func mask(of output: CIImage) -> AutoCropMask? {
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
        let cutoff = UInt8((opaqueThreshold * 255).rounded(.up))
        var valid = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) { valid[i] = bytes[i * 4 + 3] >= cutoff }
        return AutoCropMask(width: width, height: height, valid: valid)
    }
}
