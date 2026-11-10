import Foundation

/// Which scroll target the Library grid uses for a photo cell, per layout. The square grid scrolls to the cell's own id; a justified row's cells are
/// nested in a lazy stack's HStack and are not reliably scrollable by id, so that layout scrolls to the cell's ROW. Pure, so the Library's
/// restore-on-return and focus-follow code share one decision (unit-tested in `JustifiedGridSupportTests`).
enum JustifiedScrollTarget: Equatable {
    case cell(String)
    case row(Int)

    /// The id the row views carry (`.id(...)` in the grid) for row number `row`.
    static func rowViewID(_ row: Int) -> String { "justified-row-\(row)" }

    /// `justifiedRows == nil` means the square layout. In the justified layout a cell that is not in `cellIDs` or not in any row gives nil.
    static func target(forCellID id: String, cellIDs: [String], justifiedRows: [JustifiedRows.Row]?) -> JustifiedScrollTarget? {
        guard let rows = justifiedRows else { return .cell(id) }
        guard let index = cellIDs.firstIndex(of: id), let row = JustifiedRows.rowIndex(of: index, in: rows) else { return nil }
        return .row(row)
    }

    /// Whether the one-time restore of the scroll position may run now. The square grid needs nothing; the justified rows exist in their real
    /// shape only once a non-zero grid width has been measured (before that every photo sits alone in a row).
    static func canRestore(isJustified: Bool, gridWidth: Double) -> Bool {
        !isJustified || (gridWidth.isFinite && gridWidth > 0)
    }
}

/// The shape a justified-rows cell is laid out with. The file's own shape (`PhotoMetadata.displayAspect`: pixel size + EXIF orientation) is the
/// starting point, but the Library thumbnail shows the SAVED EDIT, so a rotation or crop changes the shape. Once a cell has decoded its thumbnail
/// it reports that thumbnail's own shape; only a shape that differs from the file's beyond `tolerance` is remembered (an unedited photo reports
/// nothing and never causes a re-layout).
enum ThumbnailAspect {
    /// Relative difference (in log terms) below which a thumbnail's shape counts as the file's shape: a thumbnail is rounded to whole pixels
    /// (at most ~240 on the long side), so a plain photo can be off by a fraction of a percent.
    static let tolerance = 0.02

    enum Update: Equatable {
        case keep
        case set(Double)
        case clear
    }

    /// What to do with the remembered shape of one photo after its thumbnail decoded at `thumbWidth` x `thumbHeight`.
    /// Without a usable file shape (not scanned yet) nothing is remembered: the layout treats the photo as square until the scan, and
    /// measuring then would reflow the grid once per loaded thumbnail.
    static func update(current: Double?, thumbWidth: Int, thumbHeight: Int, metadataAspect: Double?) -> Update {
        guard thumbWidth > 0, thumbHeight > 0, let metadata = metadataAspect, metadata.isFinite, metadata > 0 else { return .keep }
        let measured = Double(thumbWidth) / Double(thumbHeight)
        if abs(log(measured / metadata)) > tolerance {
            if let current, current.isFinite, current > 0, abs(log(measured / current)) <= tolerance { return .keep }
            return .set(measured)
        }
        return current == nil ? .keep : .clear
    }

    /// The shape the layout uses: the remembered thumbnail shape, else the file's, else nil (the layout then counts it as square).
    static func effective(measured: Double?, metadata: Double?) -> Double? {
        if let measured, measured.isFinite, measured > 0 { return measured }
        return metadata
    }
}
