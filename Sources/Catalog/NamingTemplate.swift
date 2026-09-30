import Foundation

/// Why a naming template can't produce a usable file name. Surfaced verbatim
/// (via `LocalizedError`) in the Export options sheet and the Library rename
/// sheet's live preview.
enum NamingError: Error, Equatable, LocalizedError {
    case emptyTemplate
    case unknownToken(String)
    case invalidSequenceWidth(String)
    case unterminatedBrace
    case strayClosingBrace
    case sequenceOutOfRange
    case emptyResult
    case tooLong

    var errorDescription: String? {
        switch self {
        case .emptyTemplate:
            return "Enter a file name template."
        case .unknownToken(let token):
            return "Unknown token {\(token)}. Available: {name} {seq} {seq:N} {date} {datetime} {rating} {label} {flag}."
        case .invalidSequenceWidth(let width):
            return "{seq:\(width)} needs a single digit count from 1 to 9, like {seq:4}."
        case .unterminatedBrace:
            return "A { has no matching }. Use {{ for a literal brace."
        case .strayClosingBrace:
            return "A } has no matching {. Use }} for a literal brace."
        case .sequenceOutOfRange:
            return "The starting sequence number must be 0 or higher and small enough to count up from."
        case .emptyResult:
            return "That template produces an empty file name."
        case .tooLong:
            return "The file name would be longer than 255 bytes."
        }
    }
}

/// Everything the template engine needs to know about ONE photo. The engine
/// only formats — callers (Export, the Library rename plan) build this from a
/// `Photo` plus a capture date, so the engine has no I/O and no catalog
/// dependency.
struct NamingContext: Sendable {
    /// The original file name without its extension.
    var baseName: String
    /// The original extension, WITHOUT the dot ("jpg", "NEF"); case preserved.
    /// Always appended to the rendered name — a template controls only the
    /// base name. It is NOT sanitized: it comes from an existing, valid file
    /// name, and the engine never invents one.
    var fileExtension: String
    /// This photo's 0-based position in the batch, in the order the caller
    /// supplied (the Library grid's displayed order for a rename; the export
    /// loop's order for an export). Position, not "count of successes": a
    /// photo that fails or is refused leaves a gap in `{seq}`.
    var sequenceIndex: Int
    /// What `{seq}` counts up from (default 1, so the first photo is `001`).
    /// Must be >= 0 — a `{seq}` that renders as `-001` would put a leading `-`
    /// in the name (a hazard for command-line tools), so a negative start (or
    /// an overflowing `start + index`) is `NamingError.sequenceOutOfRange`,
    /// never a trap. (A literal `-` the user types into the template is their
    /// own choice and is not blocked.)
    var sequenceStart: Int = 1
    /// A date whose UTC calendar digits are the capture wall-clock time — see
    /// `CaptureDate`. The engine always formats in UTC so those digits are
    /// what appear.
    var captureDate: Date
    var rating: Int = 0
    var colorLabel: ColorLabel = .none
    var flagStatus: FlagStatus = .none
}

fileprivate enum NamingToken: Equatable, Sendable {
    case name
    case seq(width: Int)
    case date
    case datetime
    case rating
    case label
    case flag
}

fileprivate enum NamingSegment: Equatable, Sendable {
    case literal(String)
    case token(NamingToken)
}

/// A template parsed ONCE, so a batch (a preview of 1000+ photos, redone on
/// every keystroke) doesn't re-parse the same string per photo. Get one from
/// `NamingTemplate.compile(_:)`.
struct CompiledNamingTemplate: Sendable {
    fileprivate let segments: [NamingSegment]

    /// True when the template contains `{date}`/`{datetime}` — so a caller can
    /// skip the (file I/O) `CaptureDate` read entirely for templates that
    /// don't need it.
    var usesCaptureDate: Bool {
        segments.contains { segment in
            if case .token(let token) = segment, token == .date || token == .datetime { return true }
            return false
        }
    }

    /// The full file name (rendered, sanitized base name + `.` + original
    /// extension) for one photo.
    func render(context: NamingContext) -> Result<String, NamingError> {
        switch renderBaseName(context: context) {
        case .success(let base):
            return .success(context.fileExtension.isEmpty ? base : base + "." + context.fileExtension)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Just the rendered, sanitized BASE name (no extension) — for callers,
    /// like Export, whose output extension differs from the source's and who
    /// add their own collision suffix. The 255-byte limit is still measured
    /// against the FULL name (`base.extension`), using `context.fileExtension`.
    func renderBaseName(context: NamingContext) -> Result<String, NamingError> {
        var base = ""
        for segment in segments {
            switch segment {
            case .literal(let text):
                base += text
            case .token(let token):
                switch NamingTemplate.value(of: token, context: context) {
                case .success(let text): base += text
                case .failure(let error): return .failure(error)
                }
            }
        }
        // A result identical to the original base name (the default `{name}`
        // template, or any template that happens to reproduce it) came from a
        // real, already-valid file name, so it is returned UNTOUCHED — even
        // when it contains something the sanitizer would otherwise strip (a
        // legal POSIX name like `a:b`, a leading dot). Callers should also
        // treat "rendered file name == original file name" as a no-op.
        let rendered = base == context.baseName ? base : NamingTemplate.sanitize(base)
        guard !rendered.isEmpty else { return .failure(.emptyResult) }

        let fileName = context.fileExtension.isEmpty ? rendered : rendered + "." + context.fileExtension
        guard fileName.utf8.count <= 255 else { return .failure(.tooLong) }
        return .success(rendered)
    }
}

/// A tiny, pure file-name template language shared by Export naming and the
/// Library "Rename Files…" feature. Tokens:
///
/// - `{name}` — original base name
/// - `{seq}` / `{seq:N}` — `sequenceStart + sequenceIndex`, zero-padded to N
///   digits (a single digit 1-9; default 3)
/// - `{date}` — capture date `yyyy-MM-dd`
/// - `{datetime}` — capture date+time `yyyyMMdd-HHmmss`
/// - `{rating}` — 0-5
/// - `{label}` — color label name in lower case (`red`…`purple`), empty when none
/// - `{flag}` — `picked` / `rejected`, empty when unflagged
/// - `{{` / `}}` — a literal `{` / `}`
///
/// The original extension is always re-appended (case preserved), so a template
/// cannot change or drop a file's existing extension (a file that has NO
/// extension can still be given one by a literal in the template).
///
/// Sanitizing (applied to a rendered base name that DIFFERS from the original
/// — see `CompiledNamingTemplate.render`): `/` and `:` are removed (a path
/// separator would escape the folder; `:` is the classic Finder path
/// separator), as is every scalar in Unicode general category Control (Cc),
/// Format (Cf — zero-width characters, bidi overrides such as U+202E that
/// spoof an extension in Finder), Line separator (Zl) or Paragraph separator
/// (Zp); then leading/trailing whitespace and dots are trimmed (a leading dot
/// would hide the file; `.`/`..` are not names). An empty result, or a full
/// file name over 255 UTF-8 bytes (`NAME_MAX`), is an error rather than a
/// silent truncation.
///
/// NOT handled here, deliberately (callers/apply must surface per-file
/// failures cleanly): characters that are legal on APFS but rejected by
/// exFAT/FAT32 (`\ * ? " < > |`) — a template containing them will fail at
/// rename/export time on such a volume; HFS+/exFAT count UTF-16 units of the
/// decomposed name, which can exceed 255 for a rare precomposed scalar even
/// when the UTF-8 byte count is within it; and case-insensitive or
/// normalization-only collisions between two rendered names, which the
/// rename plan must check (Swift `String ==` already treats canonically
/// equivalent NFC/NFD text as equal, but "IMG" != "img").
enum NamingTemplate {
    static let defaultTemplate = "{name}"

    // MARK: - Parsing

    /// Parses `template` once. Fails on empty input, an unknown token, a bad
    /// `{seq:N}`, or an unbalanced brace.
    static func compile(_ template: String) -> Result<CompiledNamingTemplate, NamingError> {
        guard !template.isEmpty else { return .failure(.emptyTemplate) }
        var segments: [NamingSegment] = []
        var literal = ""
        let chars = Array(template)
        var i = 0

        func flushLiteral() {
            if !literal.isEmpty {
                segments.append(.literal(literal))
                literal = ""
            }
        }

        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                if i + 1 < chars.count, chars[i + 1] == "{" {
                    literal.append("{")
                    i += 2
                    continue
                }
                guard let close = chars[(i + 1)...].firstIndex(of: "}") else {
                    return .failure(.unterminatedBrace)
                }
                let body = String(chars[(i + 1)..<close])
                switch token(for: body) {
                case .success(let token):
                    flushLiteral()
                    segments.append(.token(token))
                case .failure(let error):
                    return .failure(error)
                }
                i = close + 1
            } else if c == "}" {
                if i + 1 < chars.count, chars[i + 1] == "}" {
                    literal.append("}")
                    i += 2
                } else {
                    return .failure(.strayClosingBrace)
                }
            } else {
                literal.append(c)
                i += 1
            }
        }
        flushLiteral()
        return .success(CompiledNamingTemplate(segments: segments))
    }

    private static func token(for body: String) -> Result<NamingToken, NamingError> {
        switch body {
        case "name": return .success(.name)
        case "seq": return .success(.seq(width: 3))
        case "date": return .success(.date)
        case "datetime": return .success(.datetime)
        case "rating": return .success(.rating)
        case "label": return .success(.label)
        case "flag": return .success(.flag)
        default:
            if body.hasPrefix("seq:") {
                let widthText = String(body.dropFirst(4))
                // Strict: exactly one digit 1-9 (no "+4", "04", "10").
                guard widthText.count == 1, let width = Int(widthText), (1...9).contains(width) else {
                    return .failure(.invalidSequenceWidth(widthText))
                }
                return .success(.seq(width: width))
            }
            return .failure(.unknownToken(body))
        }
    }

    // MARK: - Public API

    /// Syntax-only check (no photo needed) — what the sheets call on every
    /// keystroke to enable/disable their confirm button.
    static func validate(_ template: String) -> NamingError? {
        if case .failure(let error) = compile(template) { return error }
        return nil
    }

    /// Convenience for one-off use; batches should `compile` once and call
    /// `CompiledNamingTemplate.render(context:)` per photo.
    static func render(_ template: String, context: NamingContext) -> Result<String, NamingError> {
        switch compile(template) {
        case .success(let compiled): return compiled.render(context: context)
        case .failure(let error): return .failure(error)
        }
    }

    // MARK: - Values

    fileprivate static func value(of token: NamingToken, context: NamingContext) -> Result<String, NamingError> {
        switch token {
        case .name:
            return .success(context.baseName)
        case .seq(let width):
            let (number, overflow) = context.sequenceStart.addingReportingOverflow(context.sequenceIndex)
            guard !overflow, number >= 0 else { return .failure(.sequenceOutOfRange) }
            return .success(pad(number, width))
        case .date:
            let c = utcComponents(context.captureDate)
            return .success("\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))")
        case .datetime:
            let c = utcComponents(context.captureDate)
            return .success(
                "\(pad(c.year, 4))\(pad(c.month, 2))\(pad(c.day, 2))-\(pad(c.hour, 2))\(pad(c.minute, 2))\(pad(c.second, 2))"
            )
        case .rating:
            return .success(String(min(max(context.rating, 0), 5)))
        case .label:
            switch context.colorLabel {
            case .none: return .success("")
            case .red: return .success("red")
            case .yellow: return .success("yellow")
            case .green: return .success("green")
            case .blue: return .success("blue")
            case .purple: return .success("purple")
            }
        case .flag:
            switch context.flagStatus {
            case .none: return .success("")
            case .picked: return .success("picked")
            case .rejected: return .success("rejected")
            }
        }
    }

    private static func pad(_ number: Int, _ width: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// Always UTC + Gregorian — so the digits are exactly the capture
    /// wall-clock digits (see `NamingContext.captureDate`) whatever this Mac's
    /// time zone, calendar or region is. A shared `Calendar` (Sendable, cheap)
    /// rather than a `DateFormatter` per token per photo (~0.2 ms each, which
    /// added up to ~0.4 s per keystroke for a 1000-photo preview).
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func utcComponents(_ date: Date) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    // MARK: - Sanitizing

    fileprivate static func sanitize(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            if scalar == "/" || scalar == ":" { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        let stripped = String(String.UnicodeScalarView(kept))
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        return stripped.trimmingCharacters(in: trimSet)
    }
}
