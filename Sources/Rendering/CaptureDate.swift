import Foundation
import ImageIO

/// Reads when a photo was TAKEN, for the `{date}`/`{datetime}` naming tokens.
///
/// Lookup order (first hit wins): EXIF `DateTimeOriginal` → EXIF
/// `DateTimeDigitized` → TIFF `DateTime` → the file's creation date → the
/// caller's fallback (the catalog's `importedAt`).
///
/// EXIF timestamps carry NO time zone — they are the camera's wall clock. So
/// the returned `Date` is defined such that its **UTC calendar digits are the
/// wall-clock digits** (EXIF strings are parsed as if they were UTC).
/// `NamingTemplate` always formats in UTC, so for the EXIF/TIFF branches a
/// photo's name is independent of the time zone this Mac is in. The
/// file-creation-date and `importedAt` fallbacks are real instants, so they
/// are shifted by this Mac's UTC offset AT THAT INSTANT (DST-correct) to
/// express their local wall clock the same way — those two branches therefore
/// DO depend on `TimeZone.current` when the rename runs.
///
/// Callers must hold the photo's folder scope (an unreadable file silently
/// falls through to the fallback) and should read capture dates ONCE per
/// batch, off the main thread — not per keystroke of a live preview.
enum CaptureDate {
    static func read(from url: URL, fallback: Date) -> Date {
        if let exif = exifDate(from: url) { return exif }
        if let created = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date {
            return wallClockDate(fromInstant: created)
        }
        return wallClockDate(fromInstant: fallback)
    }

    /// Re-expresses a real instant as its local wall clock, encoded as UTC digits.
    static func wallClockDate(fromInstant instant: Date, in timeZone: TimeZone = .current) -> Date {
        instant.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: instant)))
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// `"yyyy:MM:dd HH:mm:ss"` (the EXIF/TIFF date format), parsed strictly as
    /// UTC digits. Rejects the all-zero placeholder cameras write when the
    /// clock was never set (`0000:00:00 00:00:00`), non-digit fields, wrong
    /// separators, and impossible dates (`2026:02:30`, hour 24, minute 60).
    static func parseEXIFDate(_ text: String) -> Date? {
        let bytes = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        guard bytes.count == 19,
              bytes[4] == 0x3A, bytes[7] == 0x3A, bytes[10] == 0x20, bytes[13] == 0x3A, bytes[16] == 0x3A
        else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(bytes[index]) - 0x30
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              year > 0
        else { return nil }
        let components = DateComponents(
            calendar: utcCalendar, timeZone: utcCalendar.timeZone,
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        guard let date = utcCalendar.date(from: components) else { return nil }
        // `Calendar` is lenient (month 13 rolls into next year): only accept a
        // date that round-trips to the very digits that were written.
        let back = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == year, back.month == month, back.day == day,
              back.hour == hour, back.minute == minute, back.second == second
        else { return nil }
        return date
    }

    private static func exifDate(from url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates: [String?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String
        ]
        for case let text? in candidates {
            if let date = parseEXIFDate(text) { return date }
        }
        return nil
    }
}
