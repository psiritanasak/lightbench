import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Photo ▸ Import Lightroom Settings…: reads the Adobe Camera Raw (`crs:`) develop settings of the OPEN photo's `<base>.xmp` (or of any
/// `.xmp` the user picks) and applies them as one undo step. READ-ONLY: nothing is written to the `.xmp` or the photo (the edit lands
/// in this app's own sidecar like any other edit).
///
/// Flow: the menu REQUESTS -> the sidecar next to the photo is read (directly, then through a saved folder grant, else an
/// `NSOpenPanel` for any `.xmp` — the panel pick itself grants access, so no extra folder prompt) -> a confirmation dialog (with an
/// "Import with Crop" choice when the file has a crop) -> `ImageDocumentModel.applyLightroomSettings` -> a result alert.
///
/// The read happens on the main actor, on purpose: a file is refused unread above `AdobeCameraRawSettings.maximumFileSize` (16 MB),
/// real ones are ~7 KB, and the read goes through a security-scoped folder grant that belongs to the main actor.
@MainActor
final class LightroomImportModel: ObservableObject {
    struct Pending: Equatable {
        let sourceName: String
        let settings: AdobeCameraRawSettings
        let hasCrop: Bool
        /// The photo the file was read FOR; a confirm after another photo opened is refused.
        let editKey: String
        /// False when the photo's own orientation is not upright (a crop is then refused).
        let cropAllowed: Bool
        /// The photo's EXIF orientation (1...8), compared with the packet's `tiff:Orientation` for the crop; nil when it could not be read.
        let photoOrientation: Int?
        /// Names of the settings in the file that will NOT be imported (non-default ones), for the dialog.
        let ignoredNames: [String]
        /// The nominal-scale sliders and curves the file would apply (everything but Exposure), for the dialog.
        let nominalApplied: [String]
        /// Why a crop could not be imported right now (nil: it can, or the file has none).
        let cropRefusal: String?
    }

    /// What reading one file gave.
    enum ReadOutcome: Equatable {
        case data(Data)
        case notFound
        case denied
        case tooLarge
        /// A directory, FIFO, device or socket (also behind a symlink): never opened.
        case notRegular
    }

    @Published var pending: Pending?
    @Published var resultMessage: String?

    /// A confirmation is waiting (the menu is disabled meanwhile).
    var isBusy: Bool { pending != nil }

    private let folderAccess: SidecarFolderAccessing
    private let chooseFile: @MainActor (URL?) -> URL?
    private let reader: (URL) -> ReadOutcome
    private let orientation: (URL) -> CGImagePropertyOrientation?

    init(folderAccess: SidecarFolderAccessing = SidecarFolderAccess(),
         chooseFile: @escaping @MainActor (URL?) -> URL? = LightroomImportModel.runOpenPanel,
         reader: @escaping (URL) -> ReadOutcome = { LightroomImportModel.readOutcome($0) },
         orientation: @escaping (URL) -> CGImagePropertyOrientation? = { RawDecoder.readExifOrientation(of: $0) }) {
        self.folderAccess = folderAccess
        self.chooseFile = chooseFile
        self.reader = reader
        self.orientation = orientation
    }

    // MARK: - Reading

    /// Bounded read of a regular file (symlinks resolved, `FileHandle` capped at the limit + 1; see `AdobeCameraRawSettings.readCapped`):
    /// over `maximumBytes` is `.tooLarge`, a FIFO / device / directory is `.notRegular` without being opened, a permission error is
    /// `.denied`, a missing file `.notFound`.
    nonisolated static func readOutcome(_ url: URL, maximumBytes: Int = AdobeCameraRawSettings.maximumFileSize) -> ReadOutcome {
        switch AdobeCameraRawSettings.readCapped(url, maximumBytes: maximumBytes) {
        case .data(let data): return .data(data)
        case .notFound: return .notFound
        case .denied: return .denied
        case .notRegular: return .notRegular
        case .tooLarge: return .tooLarge
        }
    }

    /// `<base>.xmp`, then `<file>.xmp` (the two places a Lightroom / Camera Raw sidecar lives).
    static func candidateURLs(for photoURL: URL) -> [URL] {
        [XMPSidecarStore.sidecarURL(for: photoURL), XMPSidecarStore.alternateSidecarURL(for: photoURL)]
    }

    private func read(_ url: URL, folder: URL) -> ReadOutcome {
        let first = reader(url)
        guard first == .notFound || first == .denied, let scope = folderAccess.resolvedURL(for: folder) else { return first }
        let started = scope.startAccessingSecurityScopedResource()
        defer { if started { scope.stopAccessingSecurityScopedResource() } }
        let second = reader(url)
        if case .data = second { return second }
        return first == .denied || second == .denied ? .denied : second
    }

    // MARK: - Request

    /// Starts an import for the photo open in `document`. Does nothing without one, or while a load is in flight.
    func request(for document: ImageDocumentModel) {
        guard pending == nil, !document.isLoadInFlight, document.currentImage != nil,
              let photoURL = document.currentURL, let editKey = document.currentEditKey else { return }
        let folder = photoURL.deletingLastPathComponent()
        var source: (name: String, data: Data)?
        var deniedName: String?
        for candidate in Self.candidateURLs(for: photoURL) {
            switch read(candidate, folder: folder) {
            case .data(let data): source = (candidate.lastPathComponent, data)
            case .tooLarge:
                resultMessage = Self.tooLargeMessage(candidate.lastPathComponent)
                return
            case .denied: deniedName = deniedName ?? candidate.lastPathComponent
            case .notRegular:
                resultMessage = Self.notRegularMessage(candidate.lastPathComponent)
                return
            case .notFound: break
            }
            if source != nil { break }
        }
        if source == nil, let picked = chooseFile(folder) {
            switch reader(picked) {
            case .data(let data): source = (picked.lastPathComponent, data)
            case .tooLarge:
                resultMessage = Self.tooLargeMessage(picked.lastPathComponent)
                return
            case .denied:
                resultMessage = "Couldn't open \"\(picked.lastPathComponent)\": access was denied."
                return
            case .notRegular:
                resultMessage = Self.notRegularMessage(picked.lastPathComponent)
                return
            case .notFound:
                resultMessage = "\"\(picked.lastPathComponent)\" was not found."
                return
            }
        }
        guard let source else {
            // Nothing chosen. If a sidecar existed but could not be read, say so; a plain cancel stays silent.
            if let deniedName { resultMessage = "Couldn't read \"\(deniedName)\": access to the photo's folder was denied. Choose the .xmp file to grant access." }
            return
        }
        guard let settings = AdobeCameraRawSettings.parse(xmp: source.data) else {
            resultMessage = "\"\(source.name)\" is not a readable XMP file."
            return
        }
        guard !settings.isEmpty else {
            resultMessage = "\"\(source.name)\" has no Lightroom / Camera Raw develop settings."
            return
        }
        // An unreadable orientation is not assumed upright: the crop is refused.
        let photoOrientation = orientation(photoURL)
        let cropAllowed = photoOrientation == .up
        let photoOrientationValue = photoOrientation.map { Int($0.rawValue) }
        let plan = LightroomMapping.plan(from: settings, includeCrop: false, cropAllowed: cropAllowed)
        if let refusal = plan.refusal {
            resultMessage = refusal
            return
        }
        let hasCrop = settings.flag("HasCrop") == true
        let cropRefusal = hasCrop ? LightroomMapping.plan(from: settings, includeCrop: true, cropAllowed: cropAllowed,
                                                          photoOrientation: photoOrientationValue, target: document.editState).cropRefusal : nil
        pending = Pending(sourceName: source.name, settings: settings, hasCrop: hasCrop, editKey: editKey, cropAllowed: cropAllowed,
                          photoOrientation: photoOrientationValue, ignoredNames: plan.ignored, nominalApplied: plan.appliedNominal, cropRefusal: cropRefusal)
    }

    // MARK: - Confirm

    func cancel() { pending = nil }

    func confirm(_ request: Pending, includeCrop: Bool, document: ImageDocumentModel) {
        pending = nil
        guard !document.isLoadInFlight, document.currentEditKey == request.editKey else {
            resultMessage = "The open photo changed, so nothing was imported. Open the photo again and retry."
            return
        }
        let plan = LightroomMapping.plan(from: request.settings, includeCrop: includeCrop, cropAllowed: request.cropAllowed,
                                         photoOrientation: request.photoOrientation, target: document.editState)
        if let refusal = plan.refusal {
            resultMessage = refusal
            return
        }
        let changes = LightroomMapping.changes(of: plan, onto: document.editState)
        let applied = document.applyLightroomSettings(plan)
        resultMessage = Self.summary(plan: plan, changes: changes, applied: applied)
    }

    // MARK: - Text

    static let approximateNote = "Approximate: Lightbench renders differently from Adobe."

    /// Shown in BOTH the confirmation dialog and the result alert.
    static let honestyNote = "Only Exposure has been checked against Lightroom; the other sliders use a nominal scale and may look different."

    /// Shown when any imported curve is among the applied fields.
    static let curvesNote = "Camera Raw's curves work in a different tone space; imported curves may look different."

    /// What a full Lightroom file does to existing values.
    static let replaceNote = "A full Lightroom file sets every slider it imports, every curve and the Black & White switch it lists (including zeros) to the file's values, replacing yours."

    /// Said BEFORE confirming: what this import never touches.
    static let notImportedNote = "Not imported: Contrast, White Balance (Temperature / Tint), Sharpness, Color Grading, lens settings, masks, spot removal, Looks and other unmapped settings."

    static func tooLargeMessage(_ name: String) -> String {
        "\"\(name)\" is larger than \(AdobeCameraRawSettings.maximumFileSize / (1024 * 1024)) MB, so it was not read."
    }

    static func notRegularMessage(_ name: String) -> String { "\"\(name)\" is not a regular file, so it was not read." }

    private static func curveNames(_ names: [String]) -> Bool { names.contains { $0.hasPrefix("ToneCurvePV2012") } }

    static func confirmationTitle(_ request: Pending) -> String { "Import Lightroom settings from \"\(request.sourceName)\"?" }

    static func confirmationMessage(_ request: Pending) -> String {
        var text = "This applies the sliders and curves the file carries, as one Undo step; settings it does not mention are left alone. "
            + replaceNote + " Geometry, masks, spots and RAW decode settings are kept. Nothing is written to the .xmp."
        if request.hasCrop {
            if let refusal = request.cropRefusal { text += " The file also has a crop. " + refusal } else {
                text += " The file also has a crop; choose Import with Crop to use it (unvalidated)."
            }
        }
        text += " " + notImportedNote
        if !request.ignoredNames.isEmpty {
            text += " In this file: " + request.ignoredNames.prefix(8).joined(separator: ", ")
                + (request.ignoredNames.count > 8 ? ", and \(request.ignoredNames.count - 8) more." : ".")
        }
        text += " " + honestyNote
        if curveNames(request.nominalApplied) { text += " " + curvesNote }
        if !request.nominalApplied.isEmpty { text += " Nominal fields: " + request.nominalApplied.joined(separator: ", ") + "." }
        return text + " " + approximateNote
    }

    /// "Set N settings; also reset K sliders to 0, the point curve and Black & White. Ignored M. ..." (+ up to 6 ignored names, the
    /// honesty note, the nominal fields, a refused crop).
    static func summary(plan: LightroomMapping.Plan, changes: LightroomMapping.Changes, applied: Bool) -> String {
        let ignored = plan.ignored
        var text = "Set \(changes.setNames.count) setting\(changes.setNames.count == 1 ? "" : "s")"
        var resets: [String] = []
        if !changes.resetSliders.isEmpty { resets.append("\(changes.resetSliders.count) slider\(changes.resetSliders.count == 1 ? "" : "s") to 0") }
        if !changes.resetCurves.isEmpty { resets.append(changes.resetCurves.count == 1 ? "the point curve" : "\(changes.resetCurves.count) point curves") }
        if changes.resetBlackAndWhite { resets.append("Black & White") }
        if !resets.isEmpty {
            let joined = resets.count > 1 ? resets.dropLast().joined(separator: ", ") + " and " + resets[resets.count - 1] : resets[0]
            text += "; also reset " + joined
        }
        if changes.clearedCrop { text += "; cleared the crop" }
        text += ". Ignored \(ignored.count)."
        if !ignored.isEmpty {
            let shown = ignored.prefix(6).joined(separator: ", ")
            text += " (\(shown)\(ignored.count > 6 ? ", and \(ignored.count - 6) more" : ""))"
        }
        if let cropRefusal = plan.cropRefusal { text += " " + cropRefusal }
        if !applied { text += " The photo already had these values, so nothing changed." }
        text += " " + honestyNote
        if curveNames(plan.appliedNominal) { text += " " + curvesNote }
        if !plan.appliedNominal.isEmpty { text += " Nominal fields applied: " + plan.appliedNominal.joined(separator: ", ") + "." }
        return text + " " + approximateNote
    }

    // MARK: - Panel

    /// Any `.xmp`, starting in the photo's folder.
    static func runOpenPanel(startingIn folder: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Lightroom Settings"
        panel.message = "No .xmp sidecar could be read next to this photo. Choose a Lightroom / Camera Raw .xmp file."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let xmp = UTType(filenameExtension: "xmp") { panel.allowedContentTypes = [xmp] }
        if let folder { panel.directoryURL = folder }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Confirmation dialog and result alert for `LightroomImportModel`. Attached once in `PhotoAppApp`.
struct LightroomImportModifier: ViewModifier {
    @ObservedObject var model: LightroomImportModel
    let document: ImageDocumentModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                model.pending.map(LightroomImportModel.confirmationTitle) ?? "Import Lightroom Settings",
                isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.cancel() } }),
                titleVisibility: .visible,
                presenting: model.pending
            ) { request in
                Button("Import") { model.confirm(request, includeCrop: false, document: document) }
                if request.hasCrop, request.cropRefusal == nil {
                    Button("Import with Crop") { model.confirm(request, includeCrop: true, document: document) }
                }
                Button("Cancel", role: .cancel) { model.cancel() }
            } message: { request in
                Text(LightroomImportModel.confirmationMessage(request))
            }
            .alert(
                "Import Lightroom Settings",
                isPresented: Binding(get: { model.resultMessage != nil }, set: { if !$0 { model.resultMessage = nil } }),
                presenting: model.resultMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }
}
