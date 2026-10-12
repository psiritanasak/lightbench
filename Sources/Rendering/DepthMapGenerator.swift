import CoreImage
import Foundation

/// Produces the persisted nearness raster of a `.depthRange` mask: from the photo's EMBEDDED iPhone depth or from the bundled depth MODEL
/// (`DepthSourceResolver` decides), normalised per image by `DepthNormalizer` (0 = farthest ... 255 = nearest) and encoded as an 8-bit gray PNG in the
/// frame of the unedited, oriented photo — the same raster convention as `SubjectMaskGenerator`.
enum DepthMapGenerator {
    struct Generated: Equatable {
        let png: Data
        let width: Int
        let height: Int
        /// `DepthSourceTag.embedded` or `DepthSourceTag.model(id:revision:)`.
        let sourceTag: String
    }

    enum Outcome: Equatable {
        case generated(Generated)
        /// A sentence for the user.
        case failed(String)
    }

    /// What can be generated for `fileURL` right now (cheap: reads metadata only). For the UI's source picker.
    struct Availability: Equatable {
        let embedded: Bool
        let model: Bool
    }

    static func availability(forFileAt fileURL: URL?) -> Availability {
        Availability(embedded: fileURL.map { EmbeddedDepthReader.hasEmbeddedDepth(at: $0) } ?? false, model: DepthModelRunner.isInstalled)
    }

    /// `image` is the unedited, oriented photo; `fileURL` its file (nil for a photo that is not on disk: embedded depth is then unavailable).
    static func generate(from image: CIImage, fileURL: URL?, preference: DepthSourceResolver.Preference) async -> Outcome {
        let available = availability(forFileAt: fileURL)
        switch DepthSourceResolver.resolve(preference, embeddedAvailable: available.embedded, modelAvailable: available.model) {
        case .unavailable(let reason):
            return .failed(reason)
        case .use(.embedded):
            guard let fileURL, let field = EmbeddedDepthReader.readUpright(at: fileURL) else {
                return .failed("The iPhone depth data in this photo could not be read.")
            }
            return encode(values: field.values, width: field.width, height: field.height, tag: DepthSourceTag.embedded)
        case .use(.model):
            do {
                let output = try await DepthModelRunner.run(on: image)
                return encode(values: output.depth, width: output.width, height: output.height, tag: DepthModelRunner.sourceTag)
            } catch DepthModelRunner.RunError.notInstalled {
                return .failed(DepthSourceResolver.noModel)
            } catch DepthModelRunner.RunError.loadFailed(let message) {
                return .failed("The depth model could not be loaded: \(message)")
            } catch DepthModelRunner.RunError.renderFailed {
                return .failed("The photo could not be prepared for the depth model.")
            } catch DepthModelRunner.RunError.predictionFailed(let message) {
                return .failed("The depth model failed: \(message)")
            } catch {
                return .failed("The depth model failed: \(error.localizedDescription)")
            }
        }
    }

    /// Normalises and PNG-encodes a depth field. Pure apart from the encode; internal for tests.
    static func encode(values: [Float], width: Int, height: Int, tag: String) -> Outcome {
        guard width > 0, height > 0, values.count == width * height else { return .failed("The depth map has an unexpected size.") }
        guard let normalized = DepthNormalizer.normalize(values) else {
            return .failed("This photo's depth map has no usable variation (it is flat or empty), so a depth range cannot be selected.")
        }
        guard let png = SubjectMaskGenerator.encodePNG(.init(width: width, height: height, bytes: normalized.bytes)) else {
            return .failed("The depth map could not be saved.")
        }
        return .generated(Generated(png: png, width: width, height: height, sourceTag: tag))
    }
}
