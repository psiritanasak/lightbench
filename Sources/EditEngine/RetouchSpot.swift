import Foundation

enum RetouchMode: String, Codable, CaseIterable, Sendable {
    /// Copy the source patch, then match its tone/color to the surroundings (see `EditPipeline.applyRetouch`).
    case heal
    /// Copy the source patch exactly.
    case clone
}

/// One spot-removal spot: a circle at (`x`, `y`) repaired from a SOURCE circle displaced by (`sourceDX`, `sourceDY`).
///
/// COORDINATES live in the UNEDITED source frame — the image BEFORE straighten/perspective/scale/flip/crop —
/// and `EditPipeline` applies spots as its very first stage, so a spot stays on its content when the photo is
/// later cropped or rotated and its source can come from content that is later cropped away. (Placing/editing
/// a spot in the UI needs the inverse of those geometry stages, so v1 only allows that at identity geometry.)
///
/// - `x`, `y`: centre as fractions of the source width/height, y UP (bottom-left origin, `CIImage`'s own and
///   Red-Eye's convention — NOT SwiftUI's top-left).
/// - `radius`: fraction of `min(width, height)` — extent-relative, so proxies/thumbnails/exports repair the same
///   place. The disc fully replaced is this radius; `feather` widens the soft edge outward.
/// - `sourceDX`, `sourceDY`: offset to the source circle's centre as a fraction of `min(width, height)`
///   (isotropic, so a circle stays a circle), y up.
/// - `feather`, `opacity`: 0...1.
struct RetouchSpot: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    var x: Double = 0.5
    var y: Double = 0.5
    var radius: Double = 0.015
    var sourceDX: Double = 0.06
    var sourceDY: Double = 0
    var mode: RetouchMode = .heal
    var feather: Double = 0.5
    var opacity: Double = 1

    static let radiusRange = 0.002...0.1

    /// A spot that cannot be rendered safely (non-finite numbers) must never reach `EditState`: one NaN would
    /// make `JSONEncoder` throw and every sidecar write fail (the Point Color hazard).
    var isFinite: Bool {
        [x, y, radius, sourceDX, sourceDY, feather, opacity].allSatisfy(\.isFinite)
    }

    /// Fields clamped to their documented ranges (what the pipeline actually uses).
    var clamped: RetouchSpot {
        var s = self
        s.x = min(max(x, 0), 1)
        s.y = min(max(y, 0), 1)
        s.radius = min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
        s.feather = min(max(feather, 0), 1)
        s.opacity = min(max(opacity, 0), 1)
        return s
    }

    // MARK: Tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case id, x, y, radius, sourceDX, sourceDY, mode, feather, opacity
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.015
        sourceDX = try c.decodeIfPresent(Double.self, forKey: .sourceDX) ?? 0.06
        sourceDY = try c.decodeIfPresent(Double.self, forKey: .sourceDY) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.5
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        // A mistyped/unknown mode must not discard the spot (or the sidecar): fall back to heal.
        let rawMode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        mode = rawMode.flatMap(RetouchMode.init(rawValue:)) ?? .heal
        // Deterministic fallback so two decodes of the same id-less bytes are `==` (render cache /
        // `EditHistory` no-op guard compare whole `EditState`s), as `Mask` does.
        if let decoded = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil {
            id = decoded
        } else {
            id = Self.fallbackID(x: x, y: y, radius: radius, dx: sourceDX, dy: sourceDY, mode: mode, feather: feather, opacity: opacity)
        }
    }

    private static func fallbackID(
        x: Double, y: Double, radius: Double, dx: Double, dy: Double, mode: RetouchMode, feather: Double, opacity: Double
    ) -> UUID {
        let prime: UInt64 = 0x100000001b3
        var a: UInt64 = 0xcbf29ce484222325 ^ (mode == .heal ? 0x9e3779b97f4a7c15 : 0x517cc1b727220a95)
        var b: UInt64 = 0x9e3779b97f4a7c15
        for v in [x, y, radius, dx, dy, feather, opacity] {
            a = (a ^ v.bitPattern) &* prime
            b = (b ^ v.bitPattern.byteSwapped) &* prime
        }
        var bytes = [UInt8]()
        withUnsafeBytes(of: a.bigEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: b.bigEndian) { bytes.append(contentsOf: $0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

extension Array where Element == RetouchSpot {
    /// Makes ids unique while keeping them deterministic (the same bytes always give the same ids): the
    /// id-less fallback is a hash of the fields, so two id-less spots with identical fields would otherwise
    /// share an id and break `ForEach`/delete-by-id. A repeated id is re-derived from itself and its index.
    func withUniqueIDs() -> [RetouchSpot] {
        var seen = Set<UUID>()
        return enumerated().map { index, spot in
            var s = spot
            if !seen.insert(s.id).inserted {
                let prime: UInt64 = 0x100000001b3
                var a: UInt64 = 0xcbf29ce484222325 ^ UInt64(index + 1)
                var b: UInt64 = 0x9e3779b97f4a7c15
                Swift.withUnsafeBytes(of: s.id.uuid) { for byte in $0 { a = (a ^ UInt64(byte)) &* prime; b = (b ^ UInt64(byte).byteSwapped) &* prime } }
                var bytes = [UInt8]()
                Swift.withUnsafeBytes(of: a.bigEndian) { bytes.append(contentsOf: $0) }
                Swift.withUnsafeBytes(of: b.bigEndian) { bytes.append(contentsOf: $0) }
                bytes[6] = (bytes[6] & 0x0F) | 0x40
                bytes[8] = (bytes[8] & 0x3F) | 0x80
                s.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                   bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                seen.insert(s.id)
            }
            return s
        }
    }
}

/// Decodes an array element-by-element so ONE corrupt spot is dropped instead of discarding the whole
/// array (and, via the app's `try?`-at-the-sidecar-level convention, the whole sidecar).
struct LossyRetouchSpot: Decodable {
    let spot: RetouchSpot?
    init(from decoder: Decoder) throws { spot = try? RetouchSpot(from: decoder) }
}
