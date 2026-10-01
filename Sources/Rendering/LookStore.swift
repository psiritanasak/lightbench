import CryptoKit
import Foundation

/// Owns the on-disk folder of user-imported `.cube` looks (`Application Support/PhotoApp/Looks/`) and keeps
/// `LookLibrary` in step with it. File I/O lives here so `EditEngine` stays I/O-free.
///
/// IDS ARE PURELY CONTENT-ADDRESSED: `user:<first 12 hex of SHA-256 of the file's bytes>` — the display name is
/// NOT part of the id (it is only stored in the file name, `<hash>-<name>.cube`, for the UI). The same bytes
/// therefore always mean the same id and the same pixels on any Mac, whatever the file was called when it was
/// imported, which is what lets a sidecar name a look deterministically; re-importing identical bytes is a
/// no-op returning the existing look (also after a `remove`, so photos that used it recover); editing a file
/// and importing it again makes a NEW look rather than silently changing every photo that used the old one.
///
/// Registration must happen BEFORE any render (`loadAll()` is synchronous and called from app launch): an
/// unresolved user look renders as "no look" (fail-open), which for Export/Enhance/thumbnails would silently
/// disagree with the Editor.
final class LookStore: @unchecked Sendable {
    static let shared = LookStore(directory: LookStore.defaultDirectory())

    enum StoreError: Error, LocalizedError, Equatable {
        case tooLarge
        case unreadable
        case invalid(String)
        case cannotSave(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "That file is too large to be a LUT."
            case .unreadable: return "The file couldn't be read as text."
            case .invalid(let reason): return "Not a usable .cube file: \(reason)"
            case .cannotSave(let reason): return "Couldn't save the look: \(reason)"
            }
        }
    }

    let directory: URL
    private let library: LookLibrary
    private let lock = NSLock()

    init(directory: URL, library: LookLibrary = .shared) {
        self.directory = directory
        self.library = library
    }

    /// Under XCTest the user's real Looks folder must never be touched (same hazard D34 fixed for the catalog).
    static func defaultDirectory(isRunningUnderXCTest: Bool = CatalogDatabase.isRunningUnderXCTest) -> URL {
        if isRunningUnderXCTest {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "PhotoApp-XCTest-looks-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PhotoApp", isDirectory: true).appendingPathComponent("Looks", isDirectory: true)
    }

    // MARK: Naming

    /// A safe display name from a file name: no extension, letters/digits/space/`-`/`_` only, <= 60 characters,
    /// never empty.
    static func displayName(forFileName fileName: String) -> String {
        sanitized((fileName as NSString).deletingPathExtension)
    }

    /// Same sanitizing for a `TITLE` value, which is a NAME, not a file name: a dot in it ("Fuji v1.2") must not be
    /// mistaken for an extension and chopped.
    static func displayName(fromTitle title: String) -> String { sanitized(title) }

    private static func sanitized(_ stem: String) -> String {
        let allowed = stem.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0) }
        let cleaned = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
        let name = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Look" : name
    }

    static func hashPrefix(of data: Data) -> String {
        SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func id(hash: String) -> String { "user:\(hash)" }

    /// `(hash, name)` back out of a stored file name `<hash>-<name>.cube`, or nil if it isn't one of ours.
    static func parse(fileName: String) -> (hash: String, name: String)? {
        guard fileName.lowercased().hasSuffix(".cube") else { return nil }
        let stem = String(fileName.dropLast(5))
        guard stem.count > 13, stem.dropFirst(12).first == "-" else { return nil }
        let hash = String(stem.prefix(12))
        guard hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return (hash, String(stem.dropFirst(13)))
    }

    // MARK: Loading

    /// Registers every valid look in the folder; returns the files that were skipped (corrupt, not ours).
    /// Synchronous and called on the main thread at launch (registration must precede the first render): it reads
    /// and parses every stored file, which is milliseconds for ordinary 17-33 point LUTs.
    @discardableResult
    func loadAll() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var skipped: [String] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for fileName in names.sorted() where fileName.lowercased().hasSuffix(".cube") {
            guard let parts = Self.parse(fileName: fileName),
                  let look = loadFile(at: directory.appendingPathComponent(fileName), hash: parts.hash, name: parts.name)
            else { skipped.append(fileName); continue }
            library.register(look)
        }
        return skipped
    }

    private func loadFile(at url: URL, hash: String, name: String) -> LookLibrary.UserLook? {
        guard let data = try? readBounded(url),
              Self.hashPrefix(of: data) == hash, // 12 hex = the 6-byte prefix: a renamed/edited file must not load
              case .success(var cube) = Self.parse(data)
        else { return nil }
        cube.title = name
        return LookLibrary.UserLook(id: Self.id(hash: hash), name: name, cube: cube)
    }

    // MARK: Import / remove

    /// Parses and stores a `.cube` file (read from anywhere the sandbox allows — the caller got `url` from an
    /// `NSOpenPanel`), registers it, and returns it. Importing bytes already stored returns the existing look.
    func importCube(from url: URL) throws -> LookLibrary.UserLook {
        let data = try readBounded(url)
        let cube: CubeLUT
        switch Self.parse(data) {
        case .success(let parsed): cube = parsed
        case .failure(let error): throw error
        }
        let hash = Self.hashPrefix(of: data)
        lock.lock()
        defer { lock.unlock() }
        // Identical bytes already stored (under any name) -> that look.
        if let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .compactMap({ name in Self.parse(fileName: name).map { (name, $0) } })
            .first(where: { $0.1.hash == hash }),
           let look = loadFile(at: directory.appendingPathComponent(existing.0), hash: hash, name: existing.1.name) {
            library.register(look)
            return look
        }
        let name = cube.title.map { Self.displayName(fromTitle: $0) } ?? Self.displayName(forFileName: url.lastPathComponent)
        let fileName = "\(hash)-\(name).cube"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            throw StoreError.cannotSave(error.localizedDescription)
        }
        var stored = cube
        stored.title = name
        let look = LookLibrary.UserLook(id: Self.id(hash: hash), name: name, cube: stored)
        library.register(look)
        return look
    }

    /// Deletes the stored file and unregisters the look. Photos whose sidecar still names it render with no
    /// look and show it as missing.
    func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard id.hasPrefix("user:") else { return }
        let hash = String(id.dropFirst(5))
        // Never build a path from the id: find the stored file by its (validated) hash instead.
        let matches = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { Self.parse(fileName: $0)?.hash == hash }
        for fileName in matches {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(fileName)) }
            catch { throw StoreError.cannotSave(error.localizedDescription) }
        }
        library.unregister(id: id)
    }

    // MARK: Helpers

    /// Reads at most `CubeLUTParser.maximumBytes`. The size is checked from file attributes before reading as a
    /// memory guard (NOT observable by a test — the post-read check alone gives the same result — so it is
    /// untested by design).
    private func readBounded(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= CubeLUTParser.maximumBytes else { throw StoreError.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw StoreError.unreadable }
        guard data.count <= CubeLUTParser.maximumBytes else { throw StoreError.tooLarge }
        return data
    }

    /// `String(data:encoding:)` (not `String(decoding:)`) so a UTF-8 BOM is handled; the parser strips it too.
    static func parse(_ data: Data) -> Result<CubeLUT, StoreError> {
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
        switch CubeLUTParser.parse(text) {
        case .success(let cube): return .success(cube)
        case .failure(let error): return .failure(.invalid(error.localizedDescription))
        }
    }
}
