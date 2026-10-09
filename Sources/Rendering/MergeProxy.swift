import CoreImage
import simd

/// Proxy-sized renders shared by the merge engines (`PhotoMerger`, `PanoramaMerger`): a small linear RGBAf bitmap of a decoded frame for
/// registration and gain measurement, built through `ProxyBuilder` (which routes a RAW render through `RenderGate`).
enum MergeProxy {
    struct Bitmap {
        let width: Int
        let height: Int
        /// Linear extended-sRGB RGBAf, top row first.
        let rgba: [Float]
        /// The realised proxy image (origin 0,0), kept so it can be warped again without rebuilding it.
        let image: CIImage
    }

    /// A `longEdge`-pixel (at most) bitmap of `image` (origin 0,0), or nil if the proxy could not be built.
    static func render(_ image: CIImage, longEdge: CGFloat) async -> Bitmap? {
        let scale = min(1, longEdge / max(image.extent.width, image.extent.height))
        guard let proxy = await ProxyBuilder.build(image, scale: scale) else { return nil }
        let w = Int(proxy.extent.width), h = Int(proxy.extent.height)
        var buffer = [Float](repeating: 0, count: w * h * 4)
        PhotoExporter.context.render(proxy, toBitmap: &buffer, rowBytes: w * 16, bounds: proxy.extent, format: .RGBAf, colorSpace: PhotoMerger.linearSpace)
        return Bitmap(width: w, height: h, rgba: buffer, image: proxy)
    }

    /// Linear luminance, largest channel and coverage of `proxy` after warping it by the PROXY-space homography `h` (nil = as is) onto a
    /// `width x height` canvas of the same size.
    static func alignedLuma(of proxy: Bitmap, by h: simd_float3x3?, width: Int, height: Int) async -> (luma: [Float], peak: [Float], validity: [Float])? {
        guard proxy.width == width, proxy.height == height else { return nil }
        guard let h else { return MergeAlignment.linearLumaAndValidity(rgbaFloat: proxy.rgba, width: width, height: height) }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        guard let warped = MergeAlignment.warped(proxy.image, by: h, extent: canvas) else { return nil }
        var buffer = [Float](repeating: 0, count: width * height * 4)
        PhotoExporter.context.render(warped, toBitmap: &buffer, rowBytes: width * 16, bounds: canvas, format: .RGBAf, colorSpace: PhotoMerger.linearSpace)
        PhotoExporter.context.clearCaches() // proxy-sized, but keep the shared context from holding intermediates (same finding as ProxyBuilder)
        return MergeAlignment.linearLumaAndValidity(rgbaFloat: buffer, width: width, height: height)
    }
}
