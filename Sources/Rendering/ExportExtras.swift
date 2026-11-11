import CoreGraphics
import Foundation

/// What an export produces: the photo RENDERED with its edits into a chosen format (everything the Export sheet offers),
/// or the ORIGINAL file copied byte for byte. A separate setting, deliberately NOT an `ExportFormat` case: many places
/// loop over `ExportFormat.allCases` expecting a format an image can be encoded to.
enum ExportKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case rendered, original

    var id: String { rawValue }
    var label: String {
        switch self {
        case .rendered: return "Rendered"
        case .original: return "Original"
        }
    }
}

/// The file an original-file export wrote.
struct OriginalExportResult: Equatable, Sendable {
    var url: URL
    /// The source looked cut off (an incomplete download or card error). It was copied byte for byte anyway: the point of
    /// this mode is the file as it is, and the summary says so.
    var sourceWasTruncated: Bool
}

/// What `PhotoExporter.exportReporting` wrote and anything worth telling the user.
struct ExportOutcome: Equatable, Sendable {
    var url: URL
    /// A file-size limit was set and even the lowest quality stayed above it (the smallest result was written).
    var overLimit: Bool
}

/// Picks the highest JPEG/HEIC quality whose encoded file fits a byte limit. Pure: the encoder is a closure, so the search
/// is tested without any image. The size is NOT strictly monotonic in quality, so every probe that fits is remembered and
/// the best (highest quality) fit wins, never merely the last one.
enum FileSizeLimiter {
    struct Result: Sendable {
        var data: Data
        var quality: CGFloat
        /// False when even `minimumQuality` produced more than the limit (`data` is then the smallest seen).
        var metLimit: Bool
    }

    static let minimumQuality: CGFloat = 0.1
    /// Binary-search probes after the two end points (the range 0.1...1 narrows to about 0.007).
    static let probes = 7

    /// Nil only when an encode failed outright (the encoder returned nil for the first probes).
    static func search(limitBytes: Int, maxQuality: CGFloat, encode: (CGFloat) -> Data?) -> Result? {
        let top = min(max(maxQuality, minimumQuality), 1)
        guard let topData = encode(top) else { return nil }
        if topData.count <= limitBytes { return Result(data: topData, quality: top, metLimit: true) }
        guard let bottomData = encode(minimumQuality) else { return nil }
        if bottomData.count > limitBytes {
            // Impossible: the smallest of the two ends (the floor is almost always it).
            return bottomData.count <= topData.count
                ? Result(data: bottomData, quality: minimumQuality, metLimit: false)
                : Result(data: topData, quality: top, metLimit: false)
        }
        var best = Result(data: bottomData, quality: minimumQuality, metLimit: true)
        var fits = minimumQuality // highest quality known to fit
        var tooBig = top           // lowest quality known not to fit
        for _ in 0..<probes {
            let mid = (fits + tooBig) / 2
            guard let data = encode(mid) else { break }
            if data.count <= limitBytes {
                fits = mid
                if mid > best.quality { best = Result(data: data, quality: mid, metLimit: true) }
            } else {
                tooBig = mid
            }
        }
        return best
    }
}

/// The batch summary text, pure so its wording is tested.
enum ExportSummary {
    static func text(
        succeeded: Int, failed: Int, firstFailureMessage: String?,
        overLimit: Int = 0, original: Bool = false, truncated: Int = 0, duplicatesSkipped: Int = 0
    ) -> String {
        var part = original
            ? "Copied \(succeeded) original file\(succeeded == 1 ? "" : "s")."
            : "Exported \(succeeded) photo\(succeeded == 1 ? "" : "s")."
        if overLimit > 0 {
            part += overLimit == 1
                ? " 1 photo is over the size limit (smallest quality used)."
                : " \(overLimit) photos are over the size limit (smallest quality used)."
        }
        if truncated > 0 {
            part += " \(truncated) looked cut off (incomplete or damaged) and was copied as it is."
        }
        if duplicatesSkipped > 0 {
            part += " \(duplicatesSkipped) virtual cop\(duplicatesSkipped == 1 ? "y shared a file" : "ies shared a file") and was not copied again."
        }
        guard failed > 0 else { return part }
        var message = "\(part) \(failed) failed."
        if let firstFailureMessage {
            message += " First error: \(firstFailureMessage)"
        }
        return message
    }

    /// The result of a batch: any failed photo makes it an alert (`.incomplete`, with Show in Finder when some files were written); a clean
    /// run with a note (over the size limit, cut-off source, shared virtual-copy file) is a `.warning` toast; otherwise `.done`.
    /// The message is `text(...)`.
    static func feedback(
        succeeded: Int, failed: Int, firstFailureMessage: String?,
        overLimit: Int = 0, original: Bool = false, truncated: Int = 0, duplicatesSkipped: Int = 0,
        written: [URL]
    ) -> Feedback {
        Feedback(
            kind: FeedbackClassifier.batch(
                written: succeeded, notWritten: failed, caveats: overLimit + truncated + duplicatesSkipped
            ),
            title: "Export",
            message: text(
                succeeded: succeeded, failed: failed, firstFailureMessage: firstFailureMessage,
                overLimit: overLimit, original: original, truncated: truncated, duplicatesSkipped: duplicatesSkipped
            ),
            action: written.isEmpty ? nil : .revealInFinder(written)
        )
    }
}

/// What the Export sheet shows and enables for each `ExportKind` (pure, so the rules are tested, not only SwiftUI).
enum ExportSheetRules {
    /// Original files are copied untouched, so GPS and every other tag go with them: the sheet must say so.
    static let originalNotice = "Originals are copied unchanged, including location (GPS) and all metadata. Format, quality, colour space, sharpening, metadata, keywords, watermark and resize do not apply. Only the photo file is copied (not its edits or XMP file). A RAW+JPG pair is copied as two separate files."

    /// Every control that changes the rendered picture or its metadata. Only the file name applies to an original.
    static func renderControlsEnabled(kind: ExportKind) -> Bool { kind == .rendered }

    /// The size limit is a JPEG/HEIC rendered-export option.
    static func sizeLimitAvailable(_ settings: ExportSettings) -> Bool {
        settings.kind == .rendered && settings.format.isLossy
    }

    /// What the Metadata row says in Original mode (the picker is hidden: no policy applies, the file keeps everything).
    static let originalMetadataLabel = "Metadata: all (original file)"

    /// The destination-folder panel's message and button.
    static func folderPanel(count: Int, kind: ExportKind) -> (message: String, prompt: String) {
        switch kind {
        case .rendered: return ("Choose a folder to export \(count) photo\(count == 1 ? "" : "s") into.", "Export")
        case .original: return ("Choose a folder to copy \(count) original\(count == 1 ? "" : "s") into.", "Copy")
        }
    }

    /// The text the size-limit field should show once editing ends: the value that is really used. A number that
    /// is not a positive integer keeps the current limit (500 when none yet).
    static func effectiveSizeLimitText(typed: String, current: Int?) -> String {
        if let kb = Int(typed.trimmingCharacters(in: .whitespaces)), kb > 0, let used = ExportSettings.sanitizedFileSizeKB(kb) {
            return String(used)
        }
        return String(current ?? 500)
    }

    static func title(count: Int, kind: ExportKind) -> String {
        switch kind {
        case .rendered: return "Export \(count) Photo\(count == 1 ? "" : "s")"
        case .original: return "Copy \(count) Original\(count == 1 ? "" : "s")"
        }
    }
}
