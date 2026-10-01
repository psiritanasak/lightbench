import Foundation

/// A 3D color lookup table: `size`^3 RGBA float entries, RED varying fastest, then green, then blue —
/// both the `.cube` file order and the order `CIColorCubeWithColorSpace` expects, so `data` can be handed
/// straight to Core Image. Values are display-referred (sRGB-gamma) in 0...1.
struct CubeLUT: Equatable, Sendable {
    let size: Int
    /// `size * size * size * 4` floats (R, G, B, A=1 per entry).
    let table: [Float]
    var title: String?
    /// The table as raw Float32 bytes for `CIColorCube.cubeData`, built ONCE (a render builds a filter per
    /// frame; re-copying ~575 KB each time would be wasteful).
    let data: Data

    static let sizeRange = 2...65

    init?(size: Int, table: [Float], title: String? = nil) {
        guard Self.sizeRange.contains(size), table.count == size * size * size * 4 else { return nil }
        self.size = size
        self.table = table
        self.title = title
        self.data = table.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The identity cube: every entry maps to its own coordinate.
    static func identity(size: Int) -> CubeLUT? {
        guard sizeRange.contains(size) else { return nil }
        return build(size: size) { $0 }
    }

    /// Samples `transform` at every lattice point (inputs in 0...1), clamping outputs to 0...1.
    static func build(size: Int, title: String? = nil, _ transform: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT? {
        guard sizeRange.contains(size) else { return nil }
        var table = [Float]()
        table.reserveCapacity(size * size * size * 4)
        let last = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = transform(SIMD3(Float(r) / last, Float(g) / last, Float(b) / last))
                    table.append(min(max(out.x, 0), 1))
                    table.append(min(max(out.y, 0), 1))
                    table.append(min(max(out.z, 0), 1))
                    table.append(1)
                }
            }
        }
        return CubeLUT(size: size, table: table, title: title)
    }

    /// CPU trilinear lookup (inputs clamped to 0...1) — the reference the render tests compare against.
    func sample(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let last = Float(size - 1)
        // NaN maps to 0 (Swift's min/max pass a NaN through, and `Int(.nan)` traps); ±infinity clamp.
        func unit(_ v: Float) -> Float { v.isNaN ? 0 : min(max(v, 0), 1) }
        let p = SIMD3(unit(rgb.x), unit(rgb.y), unit(rgb.z)) * last
        let i0 = SIMD3(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)), Int(p.z.rounded(.down)))
        let i1 = SIMD3(min(i0.x + 1, size - 1), min(i0.y + 1, size - 1), min(i0.z + 1, size - 1))
        let f = p - SIMD3(Float(i0.x), Float(i0.y), Float(i0.z))
        func entry(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let base = ((b * size + g) * size + r) * 4
            return SIMD3(table[base], table[base + 1], table[base + 2])
        }
        let c00 = entry(i0.x, i0.y, i0.z) * (1 - f.x) + entry(i1.x, i0.y, i0.z) * f.x
        let c10 = entry(i0.x, i1.y, i0.z) * (1 - f.x) + entry(i1.x, i1.y, i0.z) * f.x
        let c01 = entry(i0.x, i0.y, i1.z) * (1 - f.x) + entry(i1.x, i0.y, i1.z) * f.x
        let c11 = entry(i0.x, i1.y, i1.z) * (1 - f.x) + entry(i1.x, i1.y, i1.z) * f.x
        let c0 = c00 * (1 - f.y) + c10 * f.y
        let c1 = c01 * (1 - f.y) + c11 * f.y
        return c0 * (1 - f.z) + c1 * f.z
    }
}

enum CubeLUTError: Error, Equatable, LocalizedError {
    case empty
    case missingSize
    case oneDimensional
    case unsupportedSize(Int)
    case unsupportedDomain
    case malformedLine(Int)
    case wrongEntryCount(expected: Int, found: Int)
    case nonFiniteValue(line: Int)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .empty: return "The file is empty."
        case .missingSize: return "No LUT_3D_SIZE line was found."
        case .oneDimensional: return "1D LUTs aren't supported — use a 3D .cube file."
        case .unsupportedSize(let n): return "LUT_3D_SIZE \(n) is not supported (use 2 to 65)."
        case .unsupportedDomain: return "A DOMAIN_MIN/DOMAIN_MAX other than 0 to 1 isn't supported."
        case .malformedLine(let n): return "Line \(n) isn't a valid color entry."
        case .wrongEntryCount(let expected, let found): return "Expected \(expected) color entries but found \(found)."
        case .nonFiniteValue(let n): return "Line \(n) has a value that isn't a finite number."
        case .tooLarge: return "The file is too large to be a LUT."
        }
    }
}

/// Parser for Adobe/DaVinci Resolve `.cube` 3D LUTs: `TITLE`, `LUT_3D_SIZE`, optional `DOMAIN_MIN/MAX`
/// (and Resolve's `LUT_3D_INPUT_RANGE`; accepted only as 0 to 1 — see `CubeLUTError.unsupportedDomain`), `#` comments, blank lines,
/// CRLF, then `size^3` lines of `r g b`. Pure and strict about structure, lenient about whitespace.
enum CubeLUTParser {
    /// A 65^3 cube is ~4.4 MB of text; anything beyond this is not a plausible LUT.
    static let maximumBytes = 32 * 1024 * 1024

    static func parse(_ text: String) -> Result<CubeLUT, CubeLUTError> {
        guard text.utf8.count <= maximumBytes else { return .failure(.tooLarge) }
        // A UTF-8 byte-order mark survives `String(decoding:as:)` and is not whitespace.
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var size: Int?
        var title: String?
        var values = [Float]()
        var entries = 0
        var lineNumber = 0
        var sawContent = false

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            sawContent = true
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { continue }
            switch first {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_1D_SIZE":
                return .failure(.oneDimensional)
            case "LUT_3D_SIZE":
                guard size == nil else { return .failure(.malformedLine(lineNumber)) } // a second size line would mix two cubes
                guard parts.count == 2, let n = Int(parts[1]) else { return .failure(.malformedLine(lineNumber)) }
                guard CubeLUT.sizeRange.contains(n) else { return .failure(.unsupportedSize(n)) }
                size = n
                values.reserveCapacity(n * n * n * 4)
            case "LUT_3D_INPUT_RANGE":
                // Resolve's spelling of the same idea as DOMAIN_MIN/MAX: only 0 1 is supported.
                guard parts.count == 3, let lo = Float(parts[1]), let hi = Float(parts[2]) else { return .failure(.malformedLine(lineNumber)) }
                guard lo == 0, hi == 1 else { return .failure(.unsupportedDomain) }
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let expected: Float = first == "DOMAIN_MIN" ? 0 : 1
                guard parts.count == 4 else { return .failure(.malformedLine(lineNumber)) }
                for p in parts.dropFirst() {
                    guard let v = Float(p) else { return .failure(.malformedLine(lineNumber)) }
                    guard v == expected else { return .failure(.unsupportedDomain) }
                }
            default:
                guard size != nil else {
                    // A data line before the size line (or an unknown keyword): not a valid file.
                    return .failure(Float(String(first)) != nil ? .missingSize : .malformedLine(lineNumber))
                }
                guard parts.count == 3 else { return .failure(.malformedLine(lineNumber)) }
                var rgb = [Float]()
                for p in parts {
                    guard let v = Float(p) else { return .failure(.malformedLine(lineNumber)) }
                    guard v.isFinite else { return .failure(.nonFiniteValue(line: lineNumber)) }
                    rgb.append(min(max(v, 0), 1))
                }
                entries += 1
                // Past the expected count we keep COUNTING (without storing) so the error reports the real total.
                if let n = size, entries <= n * n * n {
                    values.append(contentsOf: rgb)
                    values.append(1)
                }
            }
        }
        guard sawContent else { return .failure(.empty) }
        guard let n = size else { return .failure(.missingSize) }
        guard entries == n * n * n else { return .failure(.wrongEntryCount(expected: n * n * n, found: entries)) }
        guard let cube = CubeLUT(size: n, table: values, title: title?.isEmpty == true ? nil : title) else {
            return .failure(.unsupportedSize(n))
        }
        return .success(cube)
    }
}
