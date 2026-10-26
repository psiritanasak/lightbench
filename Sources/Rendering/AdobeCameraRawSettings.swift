import Foundation
import ImageIO
import CoreGraphics

/// The Adobe Camera Raw (`crs:`) develop settings found in an XMP packet — what Lightroom and Camera Raw write next to a RAW file
/// (`<base>.xmp`) or embed in a DNG/exported file. READ-ONLY and PURE: it parses, it never writes `crs:` anywhere, and the mapping
/// onto this app's own `EditState` lives in `LightroomMapping` (EditEngine).
///
/// Reads BOTH XMP spellings of a simple property, through ImageIO's `CGImageMetadata` (which normalises them to the same tag):
/// an attribute (`crs:Exposure2012="+0.65"`) and an element (`<crs:Exposure2012>+0.65</crs:Exposure2012>`); and the ordered
/// arrays Camera Raw uses for curves (`<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li>...`), each point an `"x, y"` string
/// on a 0...255 scale.
///
/// Tolerant by construction, never throws: garbage packets give `nil`; a malformed value is simply absent from the typed
/// accessors. The amount kept is bounded (`maximumScalarCount`, `maximumValueLength`, `maximumCurvePoints`) and `read(from:)`
/// refuses a file over `maximumFileSize` before reading it, so a hostile or corrupt sidecar cannot make the import slow or large.
///
/// The `crs:` namespace is matched by its URI, not by the prefix: a different prefix bound to the Adobe URI is accepted, and the
/// prefix `crs` bound to another URI is not.
struct AdobeCameraRawSettings: Equatable {
    /// The `crs:` namespace URI.
    static let namespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

    /// At most this many scalar properties are read from one packet (a real file has ~100-150).
    static let maximumScalarCount = 2000
    /// A scalar longer than this (in characters) is dropped (the longest real values are digests and profile names).
    static let maximumValueLength = 512
    /// At most this many points are read from one curve (Camera Raw writes up to ~16).
    static let maximumCurvePoints = 64
    /// A sidecar larger than this is refused unread (a real one is ~7 KB; one heavy with masks stays well under 1 MB).
    static let maximumFileSize = 4 * 1024 * 1024

    /// Simple properties by name WITHOUT the `crs:` prefix (`"Exposure2012"` -> `"+0.65"`), the raw text.
    private(set) var scalars: [String: String] = [:]
    /// Curves by name without the prefix (`"ToneCurvePV2012"`), points on Camera Raw's own 0...255 scale, in file order.
    /// Only points with two finite numbers are kept.
    private(set) var curves: [String: [CGPoint]] = [:]
    /// Names of `crs:` properties that are neither a simple value nor a point list: structures (`Look`, `CircularGradientBasedCorrections`
    /// entries) and arrays of structures (`MaskGroupBasedCorrections`, `RetouchAreas`, `PaintBasedCorrections`). Never interpreted;
    /// the mapping only reports them as not imported.
    private(set) var structuredNames: Set<String> = []
    /// `tiff:Orientation` (1...8) of the SAME packet: the orientation the crop edges were expressed in. nil when absent.
    private(set) var tiffOrientation: Int?

    static let tiffNamespace = "http://ns.adobe.com/tiff/1.0/"

    init() {}

    /// For tests and callers that already hold the pieces.
    init(scalars: [String: String], curves: [String: [CGPoint]] = [:], structuredNames: Set<String> = [], tiffOrientation: Int? = nil) {
        self.scalars = scalars
        self.curves = curves
        self.structuredNames = structuredNames
        self.tiffOrientation = tiffOrientation
    }

    var isEmpty: Bool { scalars.isEmpty && curves.isEmpty && structuredNames.isEmpty }

    // MARK: - Parsing

    /// nil when `data` is not a parseable XMP packet at all. A packet with no `crs:` content gives an EMPTY (not nil) result.
    static func parse(xmp data: Data) -> AdobeCameraRawSettings? {
        guard let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        return parse(metadata)
    }

    /// What a bounded read of one file gave.
    enum CappedRead: Equatable {
        case data(Data)
        case notFound
        case denied
        /// A directory, FIFO, device or socket (after resolving symlinks): never opened, so it cannot block.
        case notRegular
        case tooLarge
    }

    /// Reads at most `maximumBytes` of a REGULAR file: symlinks are resolved first and the target must be a regular file (a FIFO or
    /// device is refused before it is opened, so nothing can block), and the bytes come through a `FileHandle` capped at
    /// `maximumBytes + 1` (one over means too large), never `Data(contentsOf:)` of an unchecked path.
    nonisolated static func readCapped(_ url: URL, maximumBytes: Int = maximumFileSize) -> CappedRead {
        let resolved = url.resolvingSymlinksInPath()
        func classify(_ error: Error) -> CappedRead {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError { return .notFound }
            if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return .notFound }
            return .denied
        }
        do {
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return .notRegular }
            // Open NON-BLOCKING (a FIFO swapped in after the check would otherwise block the open), then verify the DESCRIPTOR itself
            // is a regular file before reading a byte: the path check above can race, the descriptor cannot.
            let descriptor = open(resolved.path, O_RDONLY | O_NONBLOCK)
            guard descriptor >= 0 else { return errno == ENOENT ? .notFound : .denied }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                close(descriptor)
                return .notRegular
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            return data.count > maximumBytes ? .tooLarge : .data(data)
        } catch {
            return classify(error)
        }
    }

    /// The settings of one XMP file; nil when the file cannot be read (missing, denied, not a regular file, over `maximumBytes`) or
    /// is not XMP.
    static func read(from url: URL, maximumBytes: Int = maximumFileSize) -> AdobeCameraRawSettings? {
        guard case .data(let data) = readCapped(url, maximumBytes: maximumBytes) else { return nil }
        return parse(xmp: data)
    }

    static func parse(_ metadata: CGImageMetadata) -> AdobeCameraRawSettings {
        var out = AdobeCameraRawSettings()
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return out }
        for tag in tags {
            if CGImageMetadataTagCopyNamespace(tag) as String? == tiffNamespace, CGImageMetadataTagCopyName(tag) as String? == "Orientation",
               let text = CGImageMetadataTagCopyValue(tag) as? String, let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...8).contains(value) {
                out.tiffOrientation = value
                continue
            }
            guard CGImageMetadataTagCopyNamespace(tag) as String? == namespace,
                  let name = CGImageMetadataTagCopyName(tag) as String?, !name.isEmpty else { continue }
            let value = CGImageMetadataTagCopyValue(tag)
            if let text = value as? String {
                guard out.scalars.count < maximumScalarCount, text.count <= maximumValueLength else { continue }
                out.scalars[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let items = value as? [CGImageMetadataTag] {
                let points = items.prefix(maximumCurvePoints).compactMap { item -> CGPoint? in
                    guard let text = CGImageMetadataTagCopyValue(item) as? String, text.count <= maximumValueLength else { return nil }
                    return parsePoint(text)
                }
                let allText = items.allSatisfy { CGImageMetadataTagCopyValue($0) is String }
                if allText, !points.isEmpty {
                    out.curves[name] = points
                } else if out.structuredNames.count < maximumScalarCount {
                    out.structuredNames.insert(name)   // an array of structures (masks, spots) or of non-points
                }
            } else if out.structuredNames.count < maximumScalarCount {
                out.structuredNames.insert(name)       // a structure (`crs:Look`)
            }
        }
        return out
    }

    /// `"32, 22"` -> (32, 22); nil unless exactly two finite numbers.
    static func parsePoint(_ text: String) -> CGPoint? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = parseNumber(String(parts[0])), let y = parseNumber(String(parts[1])) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Camera Raw's own number spelling: optional sign, digits, optional fraction/exponent (`+0.65`, `-12`, `0.00`, `1e2`).
    /// Anything else (empty, `nan`, `inf`, hex, words) is nil; the result is always finite.
    static func parseNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.allSatisfy({ "+-0123456789.eE".contains($0) }),
              let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    // MARK: - Typed access

    /// The raw text of a simple property.
    func text(_ name: String) -> String? { scalars[name] }

    /// A finite number; nil when absent or malformed.
    func number(_ name: String) -> Double? { scalars[name].flatMap(Self.parseNumber) }

    /// `True`/`False` (any case) or `1`/`0`; nil otherwise.
    func flag(_ name: String) -> Bool? {
        switch scalars[name]?.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    /// A curve's points on the 0...255 scale; nil when absent.
    func curve(_ name: String) -> [CGPoint]? { curves[name] }
}
