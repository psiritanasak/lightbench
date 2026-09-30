import Foundation

/// Detects a source file that was cut off partway (D37, IMPROVEMENTS.md) so
/// the paths that WRITE a new file from it (`PhotoExporter.export`,
/// `PhotoEnhancer.enhance`) can refuse instead of silently producing a
/// half-image that looks like a finished deliverable.
///
/// Why a structural check and not ImageIO: MEASURED (Phase 8 follow-up) that
/// `CGImageSourceGetStatus`/`GetStatusAtIndex` report `.statusComplete` for a
/// truncated JPEG, PNG and TIFF at every cut point tried (90%/50%/10% and
/// the last 16 bytes) — that API is only meaningful for incremental sources,
/// not local files — and that a truncated JPEG/PNG decodes to the full
/// dimensions with the missing part silently filled. (A truncated TIFF was
/// measured to fail to decode outright, so it already surfaces as an
/// unreadable source and needs no check here.)
///
/// The check walks the container's own end structure: a JPEG's first frame
/// must reach its EOI marker (`FF D9`), a PNG must reach its `IEND` chunk.
/// Walking segments/chunks (rather than looking for the marker bytes in the
/// tail) matters: a truncated camera JPEG still contains its embedded EXIF
/// thumbnail's own EOI far from the end, and a valid file may carry trailer
/// data (MPO second image, motion-photo video) after its own EOI/IEND.
///
/// One-sided by design: `.truncated` is returned only when the walk hits
/// end-of-file before the end marker, or a segment/chunk length overruns the
/// file. Anything unrecognized or oddly formed is `.unknown` and must be
/// treated as fine — a false refusal of a valid photo is worse than the
/// silent-partial-export this guards against. RAW, HEIC, WebP, GIF, BMP and
/// TIFF are `.unknown` (not measured).
///
/// KNOWN, ACCEPTED false-refusal class (reviewer-found; IMPROVEMENTS.md D37):
/// a JPEG (or PNG) whose pixel data is COMPLETE but which simply lacks its
/// final EOI (or IEND) — some older camera/scanner firmware, buggy writers,
/// sector-padded card recoveries — is reported `.truncated`, because a
/// missing end marker is indistinguishable from a cut without fully
/// decoding the entropy data to count MCUs. ImageIO decodes such files
/// fine. None of the 95 JPEGs and 49 PNGs in the developer's real library
/// hit it. The Editor still opens such a file; only export/Enhance refuse.
///
/// Not atomic with the decode that follows (a file changing between this
/// check and the decode is a narrow, accepted gap).
enum SourceIntegrity {
    enum Verdict: Equatable {
        case complete
        case truncated
        case unknown
    }

    static func verdict(forFileAt url: URL) -> Verdict {
        // Peek 8 bytes first so RAW/TIFF/HEIC (unknown anyway) never pay for a
        // whole-file read — matters for a batch export from a network volume.
        // Then an UNMAPPED read for JPEG/PNG only: `.mappedIfSafe` would mmap
        // local volumes, and a file that shrinks mid-scan (sync client
        // rewriting it, a card being pulled) would SIGBUS the whole app
        // instead of surfacing a Swift error.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 8), isJPEGOrPNG(magic) else { return .unknown }
        guard let data = try? Data(contentsOf: url) else { return .unknown }
        return verdict(for: data)
    }

    private static func isJPEGOrPNG(_ prefix: Data) -> Bool {
        prefix.starts(with: [0xFF, 0xD8]) || prefix.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    static func verdict(for data: Data) -> Verdict {
        if data.starts(with: [0xFF, 0xD8]) { return jpegVerdict(data) }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return pngVerdict(data) }
        return .unknown
    }

    // MARK: - JPEG

    static func jpegVerdict(_ data: Data) -> Verdict {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Verdict in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var i = 2 // past SOI
            while true {
                // Fill bytes: any run of 0xFF may precede a marker code.
                guard i < count else { return .truncated }
                guard bytes[i] == 0xFF else { return .unknown }
                while i < count, bytes[i] == 0xFF { i += 1 }
                guard i < count else { return .truncated }
                let marker = bytes[i]
                i += 1
                switch marker {
                case 0xD9: return .complete // EOI
                case 0x00: return .unknown // stuffed zero outside a scan — malformed
                case 0x01, 0xD0...0xD7, 0xD8: continue // standalone markers, no length
                default: break
                }
                guard i + 2 <= count else { return .truncated }
                let length = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                guard length >= 2 else { return .unknown }
                i += length
                guard i <= count else { return .truncated }
                guard marker == 0xDA else { continue } // not SOS: next segment
                // SOS: skip entropy-coded data. Inside it 0xFF is always
                // followed by 0x00 (stuffing) or RSTn; anything else is a
                // real marker that ends the scan.
                while true {
                    guard i < count else { return .truncated }
                    if bytes[i] != 0xFF { i += 1; continue }
                    guard i + 1 < count else { return .truncated }
                    let next = bytes[i + 1]
                    if next == 0x00 || (0xD0...0xD7).contains(next) { i += 2; continue }
                    if next == 0xFF { i += 1; continue } // fill
                    break // real marker at i
                }
            }
        }
    }

    // MARK: - PNG

    static func pngVerdict(_ data: Data) -> Verdict {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Verdict in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var i = 8 // past signature
            while true {
                guard i + 8 <= count else { return .truncated }
                let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
                guard length <= Int(Int32.max) else { return .unknown }
                let isIEND = bytes[i + 4] == 0x49 && bytes[i + 5] == 0x45 && bytes[i + 6] == 0x4E && bytes[i + 7] == 0x44
                i += 12 + length // length + type + data + CRC
                guard i <= count else { return .truncated }
                if isIEND { return .complete }
            }
        }
    }
}
