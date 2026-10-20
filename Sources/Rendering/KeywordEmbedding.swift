import Foundation
import ImageIO

/// Embeds a photo's catalog keywords in an EXPORTED file (never in the original). The keywords go into the image
/// properties' IPTC dictionary; ImageIO's writers then emit both the IPTC `Keywords` block and an XMP `dc:subject`
/// bag — measured 2026-10-06 (`KeywordEmbeddingTests.testWritersEmitIPTCAndXMPForEveryFormat`): JPEG, PNG and TIFF
/// written through `CIContext.write*Representation` each carry an XMP packet with `dc:subject` and read back
/// unchanged, including accented, CJK and ZWJ-emoji keywords. HEIC (`writeHEIFRepresentation`) was added to the same
/// test loop afterwards and passes it too (IPTC keywords and XMP `dc:subject` both read back identical).
enum KeywordEmbedding {
    /// `catalog` first (in the order given), then any keyword the source file already carried that the catalog does not
    /// have, de-duplicated by `KeywordName.key(for:)` (case- and normalization-insensitive; first spelling wins).
    /// Blank strings are dropped, and every name is whitespace-trimmed — source keywords included, so a source's own
    /// duplicates differing only in case/normalization collapse too.
    ///
    /// "Already carried" means what ImageIO exposes as the source's IPTC keywords (it mirrors an XMP-only `dc:subject`
    /// into that field — see `testXMPOnlySourceKeywordsAreUnioned`). For a RAW source whether `CIRAWFilter`'s output
    /// properties include the file's own keywords is UNVERIFIED (same caveat as `ExportMetadata.properties`), so a RAW
    /// export may carry only the catalog's — never more than the policy allows.
    static func merged(catalog: [String], existing: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in catalog + existing {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(KeywordName.key(for: trimmed)).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// `properties` (already filtered by `ExportMetadata.properties`) with the catalog keywords merged into its IPTC
    /// keywords. Returned UNCHANGED when `include` is off, when the policy is `.none` (an allowlist that promises no
    /// descriptive metadata — the option is ignored there, not merely disabled in the UI), or when there is nothing
    /// to add. Other IPTC fields are preserved.
    static func properties(
        _ properties: [String: Any], addingKeywords catalog: [String], policy: ExportMetadataPolicy, include: Bool
    ) -> [String: Any] {
        guard include, policy != .none, !catalog.isEmpty else { return properties }
        var result = properties
        var iptc = result[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let existing: [String]
        switch iptc[kCGImagePropertyIPTCKeywords as String] {
        case let list as [String]: existing = list
        case let single as String: existing = [single]
        default: existing = []
        }
        let combined = merged(catalog: catalog, existing: existing)
        guard !combined.isEmpty else { return properties }
        iptc[kCGImagePropertyIPTCKeywords as String] = combined
        result[kCGImagePropertyIPTCDictionary as String] = iptc
        return result
    }
}
