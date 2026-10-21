import Foundation

/// Plan for "Copy Photos into Library…": where each source photo goes in the destination folder, under what name, and which sidecar
/// files travel with it. Pure (no disk access; the caller injects what it needs to know about the disk), so every naming and collision
/// rule is unit-tested without touching files. The SOURCE is only ever read: nothing here, or in `ImportCopyEngine`, moves or deletes it.
struct ImportCopyOptions: Equatable, Sendable {
    /// How copies are grouped inside the destination folder. The date is the photo's capture wall clock (`CaptureDate`: UTC digits).
    enum Subfolders: String, CaseIterable, Sendable {
        case none
        /// `2026/10-19`
        case yearMonthDay
        /// `2026-10-19`
        case isoDate

        var title: String {
            switch self {
            case .none: return "Destination folder only"
            case .yearMonthDay: return "Year / Month-Day (2026/10-19)"
            case .isoDate: return "One folder per day (2026-10-19)"
            }
        }
    }

    /// Whether the originals stay on the card or are sent to the Trash once their copy is verified. NEVER remembered between runs
    /// (`AppPreferences` does not store it): every run starts as `.copy`.
    enum Mode: Equatable, Sendable { case copy, move }

    var mode: Mode = .copy
    var subfolders: Subfolders = .none
    /// A `NamingTemplate`; `{name}` keeps the original base name.
    var renameTemplate: String = "{name}"
    /// A destination file with the same name AND identical content is not copied again (the engine confirms by hash).
    var skipAlreadyCopied: Bool = true
}

struct ImportCopySource: Equatable, Sendable {
    let url: URL
    let fileSize: Int64
    /// Capture wall clock as UTC digits (`CaptureDate.read`).
    let captureDate: Date
}

/// DECISION (virtual copies): Copy Photos copies a photo's own edit file (`<file>.photoapp.json`) but NEVER a virtual copy's edit file
/// (`<file>.<versionKey>.photoapp.json`). The destination files get no catalog copy rows, so a version file there would be an orphan; and in
/// Move mode the original goes to the Trash while its version files stay behind in the source folder (never moved, never deleted by this
/// feature). `ImportCopyVersionSidecarTests` pins both.
struct ImportCopyPlan: Equatable, Sendable {
    /// A sidecar that follows its photo (same folder as the copy, named after the copy).
    struct Companion: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case editFile, darktableXMP, sharedXMP }
        let kind: Kind
        let source: URL
        let destination: URL

        /// Where this companion goes when its photo ends up at `photo` (the engine may pick a " (2)" name at run time).
        func destination(forPhotoAt photo: URL) -> URL {
            switch kind {
            case .editFile: return SidecarStore.sidecarURL(for: photo)
            case .darktableXMP: return XMPSidecarStore.alternateSidecarURL(for: photo)
            case .sharedXMP: return XMPSidecarStore.sidecarURL(for: photo)
            }
        }
    }

    struct Item: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Copy it. `destinationExists` is true when a file is already at `destination`: the engine then skips an identical one
            /// (if `skipAlreadyCopied`) or copies under a free " (2)" name.
            case copy(destinationExists: Bool)
            /// Not copied; the reason is shown in the result.
            case blocked(String)
        }

        let source: URL
        let destination: URL
        let kind: Kind
        let companions: [Companion]
        let fileSize: Int64
        /// The source pair this photo belongs to (source folder + base name, normalised): a RAW+JPG pair shares one, so the engine can tell a
        /// real pair from two unrelated photos that merely end up with the same base name in the destination. Empty for blocked items.
        var group: String = ""
    }

    let items: [Item]
    /// Set when the rename template is not valid; `items` is then empty.
    let templateError: NamingError?

    var copyItems: [Item] { items.filter { if case .copy = $0.kind { return true } else { return false } } }
    var blockedItems: [Item] { items.filter { if case .blocked = $0.kind { return true } else { return false } } }
    var totalBytes: Int64 { copyItems.reduce(0) { $0 + $1.fileSize } }

    /// What the plan needs to know about the disk (the real ones are `FileManager` calls; tests pass closures).
    struct Environment: Sendable {
        /// True only for a regular file: a folder named `Edits.jpg` or a symlink must never be "copied" (`copyItem` would copy the link itself).
        var isRegularFile: @Sendable (URL) -> Bool
        var exists: @Sendable (URL) -> Bool

        static let live = Environment(
            isRegularFile: { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            },
            exists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// `sources` should be in the order the user expects `{seq}` to count (the caller sorts by name or capture time).
    static func make(
        sources: [ImportCopySource], destination: URL, options: ImportCopyOptions, environment: Environment = .live
    ) -> ImportCopyPlan {
        let compiled: CompiledNamingTemplate
        switch NamingTemplate.compile(options.renameTemplate) {
        case .success(let template): compiled = template
        case .failure(let error): return ImportCopyPlan(items: [], templateError: error)
        }

        let ownership = XMPSidecarOwnership.Index(sources.map(\.url))
        var taken = Set<String>()
        // Which SOURCE pair (same source folder, same base name) owns a destination base name. A RAW+JPG pair from one folder shares
        // `<base>.xmp`, and the pair keeps one base name. Two unrelated photos that merely end up with the same base name (a camera counter
        // rollover: 100NIKON/DSC_0001.JPG and 101NIKON/DSC_0001.NEF) must NOT: they would become a fake pair sharing one xmp.
        var claims: [String: String] = [:]
        var items: [Item] = []
        var sequenceIndex = 0

        for source in sources {
            guard environment.isRegularFile(source.url) else {
                items.append(Item(source: source.url, destination: destination,
                                  kind: .blocked("Not a regular file (folders and links are skipped)"),
                                  companions: [], fileSize: source.fileSize))
                continue
            }
            let ext = source.url.pathExtension
            let sourceBase = source.url.deletingPathExtension().lastPathComponent
            let context = NamingContext(
                baseName: sourceBase, fileExtension: ext, sequenceIndex: sequenceIndex, captureDate: source.captureDate
            )
            let base: String
            switch compiled.renderBaseName(context: context) {
            case .success(let rendered): base = rendered
            case .failure(let error):
                items.append(Item(source: source.url, destination: destination, kind: .blocked(error.localizedDescription),
                                  companions: [], fileSize: source.fileSize))
                continue
            }
            sequenceIndex += 1

            let folder = destinationFolder(root: destination, date: source.captureDate, subfolders: options.subfolders)
            let group = normalized(source.url.deletingLastPathComponent().path + "/" + sourceBase)
            func fullKey(_ base: String) -> String { normalized(folder.path + "/" + base + "." + ext) }
            func baseKey(_ base: String) -> String { normalized(folder.path + "/" + base) }
            // A later photo that lands on a taken name, or on a base name another pair owns, gets " (2)", " (3)"… .
            var finalBase = base
            var suffix = 2
            while taken.contains(fullKey(finalBase)) || (claims[baseKey(finalBase)].map { $0 != group } ?? false) {
                finalBase = PhotoExporter.baseNameFitting(base, suffix: " (\(suffix))", fileExtension: ext)
                suffix += 1
            }
            taken.insert(fullKey(finalBase))
            claims[baseKey(finalBase)] = group

            let target = ext.isEmpty
                ? folder.appendingPathComponent(finalBase)
                : folder.appendingPathComponent(finalBase).appendingPathExtension(ext)
            let companions = companionFiles(for: source.url, copiedTo: target, ownership: ownership, environment: environment)
            items.append(Item(
                source: source.url, destination: target,
                kind: .copy(destinationExists: environment.exists(target)),
                companions: companions, fileSize: source.fileSize, group: group
            ))
        }
        return ImportCopyPlan(items: items, templateError: nil)
    }

    /// How the file system compares names: case- and Unicode-normalisation-insensitively.
    private static func normalized(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// The folder a photo is copied into.
    static func destinationFolder(root: URL, date: Date, subfolders: ImportCopyOptions.Subfolders) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return root }
        switch subfolders {
        case .none:
            return root
        case .yearMonthDay:
            return root.appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d-%02d", month, day), isDirectory: true)
        case .isoDate:
            return root.appendingPathComponent(String(format: "%04d-%02d-%02d", year, month, day), isDirectory: true)
        }
    }

    /// The edit file, the darktable-style `<file>.xmp`, and the shared `<base>.xmp` ONLY when this photo owns it (a RAW does; a JPEG
    /// beside a RAW does not, so one RAW+JPG pair never copies the xmp twice or hands it to the wrong file).
    private static func companionFiles(
        for source: URL, copiedTo target: URL, ownership: XMPSidecarOwnership.Index, environment: Environment
    ) -> [Companion] {
        var result: [Companion] = []
        func add(_ kind: Companion.Kind, _ from: URL) {
            guard environment.isRegularFile(from) else { return }
            let probe = Companion(kind: kind, source: from, destination: from)
            result.append(Companion(kind: kind, source: from, destination: probe.destination(forPhotoAt: target)))
        }
        add(.editFile, SidecarStore.sidecarURL(for: source))
        add(.darktableXMP, XMPSidecarStore.alternateSidecarURL(for: source))
        let owner = ownership.owner(of: source)
        if owner.standardizedFileURL.path == source.standardizedFileURL.path {
            add(.sharedXMP, XMPSidecarStore.sidecarURL(for: source))
        }
        return result
    }
}
