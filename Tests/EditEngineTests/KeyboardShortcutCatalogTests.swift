import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

@MainActor
final class KeyboardShortcutCatalogTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private var entries: [ShortcutEntry] { KeyboardShortcutCatalog.sections.flatMap(\.entries) }
    /// Every (row, source) pair: a row may document several shortcuts.
    private var sources: [ShortcutEntry.Source] { entries.flatMap(\.sources) }

    /// Every printable ASCII character: the universe a "no undocumented key" check sweeps.
    private var printable: [Character] { (32...126).compactMap { UnicodeScalar($0).map(Character.init) } }

    // MARK: menu shortcuts vs the source

    /// `.keyboardShortcut("z", modifiers: [.command, .shift])` -> `cmd+shift+z`, in a fixed modifier order.
    private func menuSpecs(in text: String) throws -> Set<String> {
        let pattern = #"\.keyboardShortcut\(\s*(?:"(.)"|\.(\w+))\s*(?:,\s*modifiers:\s*(\[[^\]]*\]|\.\w+))?\s*\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        // A shortcut mentioned in a comment is not a real one.
        let text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
        let order = ["cmd", "shift", "opt", "ctrl"]
        var specs = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
            let key: String
            if let character = group(1) { key = character } else if let named = group(2) { key = named.replacingOccurrences(of: "Arrow", with: "") } else { continue }
            var modifiers: [String] = []
            for word in (group(3) ?? "").split(whereSeparator: { !$0.isLetter }) {
                switch word {
                case "command": modifiers.append("cmd")
                case "shift": modifiers.append("shift")
                case "option": modifiers.append("opt")
                case "control": modifiers.append("ctrl")
                default: break
                }
            }
            specs.insert((modifiers.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } + [key]).joined(separator: "+"))
        }
        return specs
    }

    func testTheMenuEntriesAreExactlyTheKeyboardShortcutsInTheMenus() throws {
        let inSource = try menuSpecs(in: source("Sources/App/PhotoAppApp.swift")).union(menuSpecs(in: source("Sources/UI/AboutAndHelp.swift")))
        let listed = Set(sources.compactMap { source -> String? in
            if case .menu(let spec) = source { return spec }
            return nil
        })
        XCTAssertEqual(listed, inSource, "a menu shortcut was added, changed or removed without updating the Help list")
        XCTAssertFalse(inSource.isEmpty, "the parser found the shortcuts")
    }

    func testTheSpecParserSeesModifiersAndNamedKeys() throws {
        let specs = try menuSpecs(in: """
            // .keyboardShortcut("q", modifiers: .command)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .keyboardShortcut("c", modifiers: [.option, .command])
            """)
        XCTAssertEqual(specs, ["cmd+shift+z", "cmd+left", "cmd+opt+c"])
    }

    // MARK: photo keys vs PhotoKeyCommand

    func testEveryListedPhotoKeyIsReallyAPhotoKeyAndEveryPhotoKeyIsListed() {
        var listed = Set<Character>()
        for source in sources {
            guard case .photoKeys(let characters, let allowsZero) = source else { continue }
            for character in characters {
                XCTAssertNotNil(PhotoKeyCommand.command(for: character, allowsZero: true), "\(character) is listed but is not a photo key")
                if !allowsZero { XCTAssertNotNil(PhotoKeyCommand.command(for: character, allowsZero: false), "\(character) must work in the Editor too") }
                listed.insert(character)
            }
        }
        for character in printable where PhotoKeyCommand.command(for: character, allowsZero: true) != nil {
            XCTAssertTrue(listed.contains(character), "\"\(character)\" is a photo key that the Help list does not mention")
        }
    }

    func testZeroIsDocumentedAsAPhotoKeyOnlyWhereItRatesAndTheEditorKeepsItForZoom() {
        XCTAssertNotNil(PhotoKeyCommand.command(for: "0", allowsZero: true))
        XCTAssertNil(PhotoKeyCommand.command(for: "0", allowsZero: false), "in the Editor 0 resets the zoom")
        XCTAssertTrue(sources.contains { source in
            if case .code(_, let snippet) = source { return snippet.contains("keyPress.key == \"0\"") }
            return false
        })
    }

    func testTheListedMeaningsMatchWhatTheKeysDo() {
        XCTAssertEqual(PhotoKeyCommand.command(for: "p"), .flag(.picked))
        XCTAssertEqual(PhotoKeyCommand.command(for: "X"), .flag(.rejected))
        XCTAssertEqual(PhotoKeyCommand.command(for: "u"), .flag(FlagStatus.none))
        XCTAssertEqual(PhotoKeyCommand.command(for: "f"), .flag(nil))
        XCTAssertEqual(PhotoKeyCommand.command(for: "."), .flag(nil))
        XCTAssertEqual(PhotoKeyCommand.command(for: "6"), .label(.red))
        XCTAssertEqual(PhotoKeyCommand.command(for: "7"), .label(.yellow))
        XCTAssertEqual(PhotoKeyCommand.command(for: "8"), .label(.green))
        XCTAssertEqual(PhotoKeyCommand.command(for: "9"), .label(.blue))
        XCTAssertEqual(PhotoKeyCommand.command(for: "3"), .rating(3))
    }

    // MARK: culling keys vs CullKeyAction

    func testEveryListedCullKeyActsAndEveryCullKeyIsListed() {
        var listed: [CullKey] = []
        for source in sources {
            guard case .cull(let key) = source else { continue }
            XCTAssertNotNil(CullKeyAction.action(for: key), "\(key) is listed but does nothing")
            listed.append(key)
        }
        let named: [CullKey] = [.leftArrow, .rightArrow, .upArrow, .downArrow, .space, .escape, .returnKey]
        for key in named where CullKeyAction.action(for: key) != nil {
            XCTAssertTrue(listed.contains(key), "\(key) is a culling key that the Help list does not mention")
        }
        let photoCharacters = Set(sources.compactMap { source -> String? in
            if case .photoKeys(let characters, _) = source { return characters }
            return nil
        }.joined())
        for character in printable {
            guard let action = CullKeyAction.action(for: .character(character)) else { continue }
            if case .command = action {
                XCTAssertTrue(photoCharacters.contains(character), "\"\(character)\" rates / flags while culling but is not listed")
            } else {
                XCTAssertTrue(listed.contains(.character(Character(character.lowercased()))) || listed.contains(.character(character)),
                              "\"\(character)\" is a culling key that the Help list does not mention")
            }
        }
    }

    // MARK: everything else is pinned to its source

    func testEveryCodeEntryStillMatchesTheSourceThatImplementsIt() throws {
        var checked = 0
        for entry in entries {
            for case .code(let file, let snippet) in entry.sources {
                XCTAssertTrue(try source(file).contains(snippet), "\"\(entry.action)\" is listed, but \(file) no longer contains: \(snippet)")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 13)
    }

    func testEveryRowHasKeysTextAndAtLeastOneSourceAndNoTwoRowsShareText() {
        for section in KeyboardShortcutCatalog.sections {
            XCTAssertFalse(section.entries.isEmpty)
            for entry in section.entries {
                XCTAssertFalse(entry.keys.isEmpty, entry.action)
                XCTAssertFalse(entry.action.isEmpty, entry.keys)
                XCTAssertFalse(entry.sources.isEmpty, "\(entry.action) documents nothing checkable")
            }
            XCTAssertEqual(Set(section.entries.map(\.action)).count, section.entries.count, "\(section.title): two rows with the same text")
        }
    }

    // MARK: the window

    func testTheShortcutWindowRendersItsText() throws {
        // LIGHT system appearance on purpose: the headings must not depend on the colour scheme (they once drew black on the dark panel).
        let hosting = NSHostingView(rootView: KeyboardShortcutsView().environment(\.colorScheme, .light))
        hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        var light = 0, bright = 0, darkerThanThePanel = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.5, c.greenComponent > 0.5 { light += 1 }
                if c.redComponent > 0.8, c.greenComponent > 0.8, c.blueComponent > 0.8 { bright += 1 }
                if c.redComponent < 0.07, c.greenComponent < 0.07, c.blueComponent < 0.07 { darkerThanThePanel += 1 }
            }
        }
        XCTAssertGreaterThan(light, 500, "the key names and descriptions are drawn")
        XCTAssertGreaterThan(bright, 80, "the key names are near-white")
        XCTAssertEqual(darkerThanThePanel, 0, "nothing is drawn darker than the panel (0.11 grey): black heading text would be")
    }

    // MARK: About

    func testTheAboutCreditsNameTheDependenciesAndLinkTheNoticesWhenTheyExist() {
        let url = URL(fileURLWithPath: "/tmp/ThirdPartyNotices.md")
        let with = AboutPanelContent.credits(noticesURL: url)
        XCTAssertTrue(with.string.contains("GRDB"))
        XCTAssertTrue(with.string.contains("Depth Anything"))
        XCTAssertTrue(with.string.contains("never modified"))
        let range = (with.string as NSString).range(of: "Third-party licences")
        XCTAssertEqual(with.attribute(.link, at: range.location, effectiveRange: nil) as? URL, url)
        let without = AboutPanelContent.credits(noticesURL: nil)
        XCTAssertNil(without.attribute(.link, at: (without.string as NSString).range(of: "Third-party licences").location, effectiveRange: nil))
    }

    func testTheLicenceNoticesAreReallyBundledInTheApp() throws {
        let url = try XCTUnwrap(AboutPanelContent.noticesURL(), "ThirdPartyNotices.md is not a bundle resource (project.yml)")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("GRDB"))
        XCTAssertTrue(text.contains("Apache"))
    }

    // MARK: wiring pins

    func testTheAppRegistersTheAboutHelpAndShortcutWindowItems() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("AboutAndHelpCommands()"))
        XCTAssertTrue(app.contains("Window(\"Keyboard Shortcuts\", id: AboutAndHelpCommands.shortcutsWindowID)"))
        let help = try source("Sources/UI/AboutAndHelp.swift")
        XCTAssertTrue(help.contains("CommandGroup(replacing: .appInfo)"))
        XCTAssertTrue(help.contains("CommandGroup(replacing: .help)"))
        XCTAssertTrue(help.contains("orderFrontStandardAboutPanel"))
    }
}
