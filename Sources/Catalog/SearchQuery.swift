import Foundation

/// The Library search box's query language: whitespace-separated terms that must ALL match.
///
/// - a plain word, or a `"quoted phrase"`, matches a filename OR a keyword name (case-insensitive substring), as before;
/// - `field:value` filters on one attribute. Fields: `iso`, `focal` (mm), `aperture` (`f2.8`/`2.8`), `shutter`
///   (`1/250`, `0.5`, `2s`), `date` (`2023`, `2023-03`, `2023-03-14`), `rating`, `flag` (`pick|reject|none`),
///   `label` (`red|yellow|green|blue|purple|none`), `keyword`, `name`, `camera` (make/model), `lens`;
/// - numeric and date fields take `>`, `>=`, `<`, `<=`, `=` or a range `a..b` (`iso:>800`, `date:2023-01..2023-06`);
///   a date with fewer parts means the whole period (`date:2023-03` is every day of March) and a comparison uses the
///   period's edge (`date:>2023-03` is after March, `date:<=2023-03` through the end of March);
/// - a value may be quoted (`camera:"Nikon D610"`).
///
/// An unknown `field:` is plain text (so a filename like `http:x` still searches). A known field with NO value yet
/// (`iso:` while typing) is ignored. A known field whose value cannot be read (`iso:abc`) matches NOTHING and is listed in
/// `invalidTerms` so the UI can say why. Photos with no cached camera data never match a camera-data field.
struct SearchQuery: Equatable {
    enum Field: String, CaseIterable {
        case iso, focal, aperture, shutter, date, rating, flag, label, keyword, name, camera, lens
    }

    enum Comparison: Equatable {
        case equal(Double), greater(Double), greaterOrEqual(Double), less(Double), lessOrEqual(Double)
        case range(Double, Double)
    }

    enum Term: Equatable {
        case text(String)
        case number(Field, Comparison)
        case contains(Field, String)
        case flag(FlagStatus)
        case label(ColorLabel)
        /// A known field with an unreadable value: nothing matches.
        case invalid(String)
    }

    var terms: [Term] = []

    /// The terms the user typed that could not be read (shown as a hint).
    var invalidTerms: [String] {
        terms.compactMap { if case .invalid(let text) = $0 { return text } else { return nil } }
    }

    var isEmpty: Bool { terms.isEmpty }

    /// True when any term needs the photo's cached camera data (so the UI can say "still reading camera data").
    var usesCameraData: Bool {
        terms.contains { term in
            switch term {
            case .number(let field, _), .contains(let field, _): return Self.cameraFields.contains(field)
            default: return false
            }
        }
    }

    private static let cameraFields: Set<Field> = [.iso, .focal, .aperture, .shutter, .date, .camera, .lens]

    // MARK: - Parsing

    init(parsing text: String) {
        for token in Self.tokenize(text) {
            if let term = Self.term(from: token) { terms.append(term) }
        }
    }

    private struct Token { var text: String; var raw: String }

    /// Splits on whitespace outside quotes; quote characters are removed from the token text.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = "", raw = ""
        var inQuotes = false, quoted = false
        func flush() {
            if !current.isEmpty || quoted { tokens.append(Token(text: current, raw: raw)) }
            current = ""; raw = ""; quoted = false
        }
        for char in text {
            if char == "\"" {
                inQuotes.toggle(); quoted = true; raw.append(char)
            } else if char.isWhitespace && !inQuotes {
                flush()
            } else {
                current.append(char); raw.append(char)
            }
        }
        flush()
        return tokens
    }

    private static func term(from token: Token) -> Term? {
        // `field:value` only when the text before the first colon names a known field. A token that BEGINS with a quote is a
        // phrase even if it looks like a field (`"iso:>800"` searches for that text).
        if !token.raw.hasPrefix("\""), let colon = token.text.firstIndex(of: ":") {
            let name = String(token.text[..<colon]).lowercased()
            if let field = Field(rawValue: name) {
                let value = String(token.text[token.text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                // Nothing to filter on yet (`iso:`, or just an operator while typing `iso:>800`): ignore, don't empty the grid.
                if value.isEmpty || ["=", ">", "<", ">=", "<=", ".."].contains(value) { return nil }
                return fieldTerm(field, value: value, raw: token.raw)
            }
        }
        let trimmed = token.text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : .text(trimmed)
    }

    private static func fieldTerm(_ field: Field, value: String, raw: String) -> Term {
        switch field {
        case .keyword, .name, .camera, .lens:
            return .contains(field, value)
        case .flag:
            switch value.lowercased() {
            case "pick", "picked", "flagged": return .flag(.picked)
            case "reject", "rejected": return .flag(.rejected)
            case "none", "unflagged": return .flag(.none)
            default: return .invalid(raw)
            }
        case .label:
            switch value.lowercased() {
            case "red": return .label(.red)
            case "yellow": return .label(.yellow)
            case "green": return .label(.green)
            case "blue": return .label(.blue)
            case "purple": return .label(.purple)
            case "none", "unlabeled", "unlabelled": return .label(.none)
            default: return .invalid(raw)
            }
        case .iso, .focal, .aperture, .shutter, .date, .rating:
            if let comparison = comparison(field, value: value) { return .number(field, comparison) }
            return .invalid(raw)
        }
    }

    // MARK: Numeric / date values

    private static func comparison(_ field: Field, value: String) -> Comparison? {
        if let dots = value.range(of: "..") {
            let low = String(value[..<dots.lowerBound]), high = String(value[dots.upperBound...])
            // `2...4` splits as `2.` / `.4`: a stray dot next to the `..` is a typo, not a number.
            guard !low.isEmpty, !high.isEmpty, !low.hasSuffix("."), !high.hasPrefix("."),
                  var lo = scalar(field, low, edge: .start), var hi = scalar(field, high, edge: .end)
            else { return nil }
            // Photographers write shutter ranges slow-to-fast (`1/30..1/250`): accept either order for plain numbers. A
            // reversed DATE range stays invalid (far more likely a typo than an intent), including adjacent periods whose
            // edges coincide (`2023-04..2023-03` would otherwise become an empty interval that matches nothing, silently).
            if field == .date {
                guard lo < hi else { return nil }
            } else if lo > hi {
                swap(&lo, &hi)
            }
            return .range(lo, hi)
        }
        for prefix in [">=", "<=", ">", "<", "="] where value.hasPrefix(prefix) {
            let rest = String(value.dropFirst(prefix.count))
            if field == .date {
                // Dates are periods: compare against the right edge (the end is EXCLUSIVE).
                guard let period = datePeriod(rest) else { return nil }
                switch prefix {
                case ">": return .greaterOrEqual(period.end)      // after the whole period
                case ">=": return .greaterOrEqual(period.start)
                case "<": return .less(period.start)              // before the period
                case "<=": return .less(period.end)               // through the whole period
                default: return .range(period.start, period.end)  // "=": the period itself
                }
            }
            guard let number = scalar(field, rest, edge: .start) else { return nil }
            switch prefix {
            case ">=": return .greaterOrEqual(number)
            case "<=": return .lessOrEqual(number)
            case ">": return .greater(number)
            case "<": return .less(number)
            default: return .equal(number)
            }
        }
        if field == .date {
            // A bare date is the whole period.
            guard let period = datePeriod(value) else { return nil }
            return .range(period.start, period.end)
        }
        return scalar(field, value, edge: .start).map { .equal($0) }
    }

    private enum Edge { case start, end }

    /// One value of `field`, in the field's stored unit. For dates `edge` picks the start or the (exclusive) end of the period.
    private static func scalar(_ field: Field, _ text: String, edge: Edge) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces)
        switch field {
        case .iso, .rating:
            guard let number = Double(value), number.isFinite, number >= 0 else { return nil }
            return number
        case .focal:
            var v = value.lowercased()
            if v.hasSuffix("mm") { v.removeLast(2) }
            guard let number = Double(v), number.isFinite, number > 0 else { return nil }
            return number
        case .aperture:
            var v = value.lowercased()
            if v.hasPrefix("f/") { v.removeFirst(2) } else if v.hasPrefix("f") { v.removeFirst() }
            guard let number = Double(v), number.isFinite, number > 0 else { return nil }
            return number
        case .shutter:
            var v = value.lowercased()
            if v.hasSuffix("s") { v.removeLast() }
            if let slash = v.firstIndex(of: "/") {
                guard let num = Double(v[..<slash]), let den = Double(v[v.index(after: slash)...]),
                      num.isFinite, den.isFinite, num > 0, den > 0 else { return nil }
                return num / den
            }
            guard let number = Double(v), number.isFinite, number > 0 else { return nil }
            return number
        case .date:
            guard let period = datePeriod(value) else { return nil }
            return edge == .start ? period.start : period.end
        default:
            return nil
        }
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// `2023`, `2023-03` or `2023-03-14` (also with `/` or `.` separators) as the half-open UTC interval it covers.
    private static func datePeriod(_ text: String) -> (start: Double, end: Double)? {
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { "-/.".contains($0) }).map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        guard let year = Int(parts[0]), parts[0].count == 4, year > 0 else { return nil }
        var components = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone, year: year)
        let unit: Calendar.Component
        switch parts.count {
        case 1: components.month = 1; components.day = 1; unit = .year
        case 2:
            guard parts[1].count <= 2, let month = Int(parts[1]), (1...12).contains(month) else { return nil }
            components.month = month; components.day = 1; unit = .month
        default:
            guard parts[1].count <= 2, parts[2].count <= 2, let month = Int(parts[1]), (1...12).contains(month),
                  let day = Int(parts[2]), (1...31).contains(day) else { return nil }
            components.month = month; components.day = day; unit = .day
        }
        guard let start = utcCalendar.date(from: components),
              // Reject days that roll over (2023-02-30).
              utcCalendar.component(.month, from: start) == components.month,
              let end = utcCalendar.date(byAdding: unit, value: 1, to: start)
        else { return nil }
        return (start.timeIntervalSince1970, end.timeIntervalSince1970)
    }

    // MARK: - Matching

    func matches(_ photo: Photo, metadata: PhotoMetadata?, keywordNames: [String]) -> Bool {
        terms.allSatisfy { Self.matches($0, photo: photo, metadata: metadata, keywordNames: keywordNames) }
    }

    private static func matches(_ term: Term, photo: Photo, metadata: PhotoMetadata?, keywordNames: [String]) -> Bool {
        switch term {
        case .invalid:
            return false
        case .text(let text):
            return photo.filename.localizedCaseInsensitiveContains(text)
                || keywordNames.contains { $0.localizedCaseInsensitiveContains(text) }
        case .flag(let status):
            return photo.flagStatus == status
        case .label(let label):
            return photo.colorLabel == label
        case .contains(let field, let text):
            switch field {
            case .keyword: return keywordNames.contains { $0.localizedCaseInsensitiveContains(text) }
            case .name: return photo.filename.localizedCaseInsensitiveContains(text)
            case .camera:
                guard let metadata else { return false }
                return [metadata.cameraName, metadata.cameraMake, metadata.cameraModel].contains {
                    $0?.localizedCaseInsensitiveContains(text) == true
                }
            case .lens: return metadata?.lens?.localizedCaseInsensitiveContains(text) == true
            default: return false
            }
        case .number(let field, let comparison):
            let value: Double?
            switch field {
            case .rating: value = Double(photo.rating)
            case .iso: value = metadata?.iso.map(Double.init)
            case .focal: value = metadata?.focalLength
            case .aperture: value = metadata?.aperture
            case .shutter: value = metadata?.shutter
            case .date: value = metadata?.captureDate
            default: value = nil
            }
            guard let value else { return false }
            return matches(value, comparison, field: field)
        }
    }

    /// Camera-reported numbers are rounded differently by different bodies (2.8 vs 2.79999, 1/250 vs 0.004), so `=` on
    /// aperture, focal length and shutter tolerates 1 %; ISO and rating compare exactly; dates are intervals. The 1 % is only safe
    /// because `PhotoMetadataReader` stores FNumber/ExposureTime, not the APEX tags (APEX f/2.8 is 2.828, 1/250 is 1/256).
    private static func matches(_ value: Double, _ comparison: Comparison, field: Field) -> Bool {
        switch comparison {
        case .equal(let target):
            switch field {
            case .aperture, .focal, .shutter: return abs(value - target) <= target * 0.01
            default: return abs(value - target) < 0.5
            }
        case .greater(let target): return value > target
        case .greaterOrEqual(let target): return value >= target
        case .less(let target): return value < target
        case .lessOrEqual(let target): return value <= target
        case .range(let low, let high):
            // Dates are half-open intervals; the number fields' `a..b` is inclusive at both ends.
            return field == .date ? (value >= low && value < high) : (value >= low && value <= high)
        }
    }
}

/// The search help popover's content (kept as data so a test can check it against the parser).
enum SearchHelp {
    struct Row: Equatable {
        var field: String
        var meaning: String
        var example: String
    }

    static let rows: [Row] = [
        Row(field: "iso", meaning: "ISO speed", example: "iso:>800"),
        Row(field: "camera", meaning: "Camera make or model", example: "camera:d610"),
        Row(field: "lens", meaning: "Lens", example: "lens:50mm"),
        Row(field: "focal", meaning: "Focal length (mm)", example: "focal:24..70"),
        Row(field: "aperture", meaning: "F-number", example: "aperture:<=f2.8"),
        Row(field: "shutter", meaning: "Exposure time", example: "shutter:<1/250"),
        Row(field: "date", meaning: "Capture date (year, month or day)", example: "date:2023-03"),
        Row(field: "rating", meaning: "Star rating", example: "rating:>=4"),
        Row(field: "flag", meaning: "pick, reject or none", example: "flag:pick"),
        Row(field: "label", meaning: "Colour label", example: "label:red"),
        Row(field: "keyword", meaning: "Keyword", example: "keyword:mountains"),
        Row(field: "name", meaning: "File name", example: "name:IMG_6")
    ]

    static let note = "Combine terms with spaces; all must match. Use > >= < <= or a..b for numbers and dates, and quotes for phrases."
}
