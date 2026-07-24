import CoreGraphics

/// Computes the rect an image of `imageSize` should occupy, centered and
/// scaled to fit entirely within `containerSize` while preserving aspect ratio.
enum AspectFit {
    static func rect(fitting imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )

        let fittedWidth = imageSize.width * scale
        let fittedHeight = imageSize.height * scale

        let originX = (containerSize.width - fittedWidth) / 2
        let originY = (containerSize.height - fittedHeight) / 2

        return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
    }
}
