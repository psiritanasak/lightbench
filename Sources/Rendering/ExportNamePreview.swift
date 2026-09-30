import Foundation

/// What the Export options sheet should show for its "File name" field — pure,
/// so the rules (which states block Export, when to show nothing) are unit
/// tested instead of living only in SwiftUI.
///
/// - `.example`: the template compiles and the FIRST photo renders — show
///   "Example: …" in the normal style.
/// - `.templateError`: the template itself is invalid (syntax/token) — show
///   the error in red and DISABLE Export; every photo would fail.
/// - `.photoError`: the template is fine but the first photo can't render
///   (`{label}` on an unlabeled photo → empty name, or too long). Show a
///   warning but do NOT disable Export — other photos may render fine and a
///   per-photo failure is already reported by the batch summary.
/// - `.waitingForDate`: the template needs the capture date and it hasn't been
///   read yet — show nothing rather than an example built from the import-date
///   fallback (which can be a visibly different day).
enum ExportNamePreview: Equatable {
    case example(String)
    case templateError(NamingError)
    case photoError(NamingError)
    case waitingForDate

    /// True only when Export must be disabled.
    var blocksExport: Bool {
        if case .templateError = self { return true }
        return false
    }

    static func evaluate(
        template: String, photo: Photo?, format: ExportFormat, captureDate: Date?
    ) -> ExportNamePreview? {
        let compiled: CompiledNamingTemplate
        switch NamingTemplate.compile(template) {
        case .success(let value): compiled = value
        case .failure(let error): return .templateError(error)
        }
        guard let photo else { return nil }
        if compiled.usesCaptureDate && captureDate == nil { return .waitingForDate }
        do {
            let base = try PhotoExporter.destinationBaseName(
                for: photo, format: format, compiled: compiled, sequenceIndex: 0,
                captureDate: captureDate ?? photo.importedAt
            )
            return .example(base + "." + format.fileExtension)
        } catch PhotoExportError.invalidNaming(let error) {
            return .photoError(error)
        } catch {
            return nil
        }
    }
}
