import Foundation
import GRDB

/// Cached camera data for one photo (see `Migration014PhotoMetadata`). Every payload field is optional: files differ in
/// what they carry, and a photo with none of it still has a row so it is not re-read.
struct PhotoMetadata: Codable, Equatable, Hashable, Sendable {
    /// Bumped when the reader starts extracting something new (or fixes a parse), which makes every older row stale.
    static let currentReaderRevision = 1

    var photoId: Int64
    var fileSize: Int64
    /// `modificationDate.timeIntervalSince1970` when read.
    var mtime: Double
    var readerRevision: Int
    /// The camera's wall-clock capture time with its digits placed in UTC (the convention of `CaptureDate.parseEXIFDate`), as
    /// seconds since 1970, or nil when the file has no usable EXIF/TIFF date. It deliberately does NOT use
    /// `CaptureDate.read`'s fallbacks (file creation date, import date): a made-up date would pollute date search. Never
    /// converted to the Mac's time zone, so a photo taken at 09:00 local reads 09:00 anywhere; date queries must compare in a
    /// UTC calendar.
    var captureDate: Double?
    var iso: Int?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    /// Millimetres.
    var focalLength: Double?
    /// F-number (2.8 for f/2.8).
    var aperture: Double?
    /// Exposure time in seconds (0.004 for 1/250).
    var shutter: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// Informational only; it comes back from the database truncated to milliseconds, so never use whole-row equality to
    /// decide that nothing changed.
    var scannedAt: Date

    /// True while the file still looks as it did when this row was read AND the row came from the current reader.
    func isCurrent(fileSize currentSize: Int64, mtime currentMTime: Double) -> Bool {
        readerRevision == Self.currentReaderRevision && fileSize == currentSize && abs(mtime - currentMTime) < 0.001
    }

    /// "Make Model" for search and display, without repeating the make when the model already starts with it
    /// (Nikon writes `NIKON CORPORATION` / `NIKON D610`; Canon writes `Canon` / `Canon EOS R5`).
    var cameraName: String? {
        let make = cameraMake?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = cameraModel?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty { return model }
        // Drop the make only when the model already STARTS WITH THE SAME WORD (a whole word, any case).
        let makeWord = make.split(separator: " ").first.map { $0.lowercased() } ?? make.lowercased()
        let modelWord = model.split(separator: " ").first.map { $0.lowercased() } ?? model.lowercased()
        return makeWord == modelWord ? model : "\(make) \(model)"
    }
}

extension PhotoMetadata: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "photo_metadata"

    enum Columns {
        static let photoId = Column(CodingKeys.photoId)
        static let fileSize = Column(CodingKeys.fileSize)
        static let mtime = Column(CodingKeys.mtime)
        static let readerRevision = Column(CodingKeys.readerRevision)
        static let captureDate = Column(CodingKeys.captureDate)
        static let iso = Column(CodingKeys.iso)
        static let cameraMake = Column(CodingKeys.cameraMake)
        static let cameraModel = Column(CodingKeys.cameraModel)
        static let lens = Column(CodingKeys.lens)
        static let focalLength = Column(CodingKeys.focalLength)
        static let aperture = Column(CodingKeys.aperture)
        static let shutter = Column(CodingKeys.shutter)
        static let pixelWidth = Column(CodingKeys.pixelWidth)
        static let pixelHeight = Column(CodingKeys.pixelHeight)
        static let scannedAt = Column(CodingKeys.scannedAt)
    }
}
