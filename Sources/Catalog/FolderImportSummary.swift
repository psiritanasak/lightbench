import Foundation

// MARK: - Folder import report

/// How one folder's import ended.
enum FolderImportOutcome: Equatable, Sendable {
    case imported(ImportResult)
    case noPhotos
    case failed(String)
}

/// One folder's import result plus the access warning (if any) that came with it.
struct FolderImportReport: Equatable, Sendable {
    let folderName: String
    let outcome: FolderImportOutcome
    let accessWarning: String?
}

/// The text and kind of a folder import's result (one folder, or several imported in one go). Pure.
enum FolderImportSummary {
    static let noPhotosMessage = "No photos found in that folder."

    /// One folder's message, without its access warning.
    static func message(_ outcome: FolderImportOutcome) -> String {
        switch outcome {
        case .imported(let result):
            let importedPart = "Imported \(result.inserted) photo\(result.inserted == 1 ? "" : "s")"
            guard result.skipped > 0 else { return "\(importedPart)." }
            return "\(importedPart) (\(result.skipped) already in catalog)."
        case .noPhotos:
            return noPhotosMessage
        case .failed(let reason):
            return "Import failed: \(reason)"
        }
    }

    /// The combined message: each folder's message (plus its access warning, except after a failure), prefixed with the folder name when
    /// there are several, one per line.
    static func text(_ reports: [FolderImportReport]) -> String {
        reports.map { report in
            var line = message(report.outcome)
            if case .failed = report.outcome {} else if let warning = report.accessWarning { line += " \(warning)" }
            return reports.count > 1 ? "\(report.folderName): \(line)" : line
        }.joined(separator: "\n")
    }

    /// The result as a `Feedback`: a failure or an access warning means something asked for was not fully done, so it is an alert.
    static func feedback(_ reports: [FolderImportReport], title: String = "Photo Catalog") -> Feedback {
        let message = text(reports)
        if reports.count == 1, case .failed = reports[0].outcome { return .error(title, message) }
        var written = 0, unchanged = 0, notWritten = 0
        for report in reports {
            switch report.outcome {
            case .imported(let result):
                written += result.inserted
                unchanged += result.skipped
                if report.accessWarning != nil { notWritten += 1 }
            case .noPhotos:
                if report.accessWarning != nil { notWritten += 1 }
            case .failed:
                notWritten += 1
            }
        }
        return Feedback(kind: FeedbackClassifier.batch(written: written, unchanged: unchanged, notWritten: notWritten), title: title, message: message)
    }
}
