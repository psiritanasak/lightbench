import XCTest
@testable import PhotoApp

/// `HistoryArchive`: the compact JSON form of an `EditHistory` that is persisted inside a sidecar.
final class HistoryArchiveTests: XCTestCase {
    private func state(_ configure: (inout EditState) -> Void) -> EditState {
        var s = EditState()
        configure(&s)
        return s
    }

    private func history(_ steps: [(EditState, String)], cursor: Int? = nil) -> EditHistory {
        var h = EditHistory(.identity, initialSummary: "Opened")
        for (s, summary) in steps { h.commit(s, summary: summary) }
        if let cursor { while h.currentIndex > cursor { h.undo() } }
        return h
    }

    private func roundTrip(_ h: EditHistory, requiring current: [String: Any]? = nil) throws -> HistoryArchive? {
        let object = try XCTUnwrap(HistoryArchive(h).jsonObject())
        let data = try JSONSerialization.data(withJSONObject: object)
        return HistoryArchive.decode(try JSONSerialization.jsonObject(with: data), requiringCurrentState: current)
    }

    private func stateObject(_ s: EditState) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
    }

    // MARK: - Round trip

    func testRoundTripKeepsEntriesIDsSummariesStatesAndTheCursor() throws {
        let h = history([
            (state { $0.exposureEV = 0.5 }, "Exposure"),
            (state { $0.exposureEV = 0.5; $0.contrast = 0.2 }, "Contrast"),
            (state { $0.exposureEV = 0.1; $0.contrast = 0.2 }, "Exposure again"),
        ])
        let archive = try XCTUnwrap(try roundTrip(h))
        XCTAssertEqual(archive.currentIndex, h.currentIndex)
        XCTAssertEqual(archive.entries.map(\.id), h.entries.map(\.id))
        XCTAssertEqual(archive.entries.map(\.summary), h.entries.map(\.summary))
        XCTAssertEqual(archive.entries.map(\.state), h.entries.map(\.state))
    }

    func testAMidTimelineCursorWithAbandonedRedoEntriesSurvives() throws {
        let h = history([
            (state { $0.exposureEV = 1 }, "A"), (state { $0.exposureEV = 2 }, "B"), (state { $0.exposureEV = 3 }, "C"),
        ], cursor: 1)
        XCTAssertEqual(h.currentIndex, 1)
        XCTAssertTrue(h.canRedo)
        let archive = try XCTUnwrap(try roundTrip(h))
        XCTAssertEqual(archive.currentIndex, 1)
        XCTAssertEqual(archive.entries.count, 4, "the redo branch is part of the timeline")
        XCTAssertEqual(archive.entries[1].state.exposureEV, 1)
        let restored = try XCTUnwrap(EditHistory(restoring: archive.entries, currentIndex: archive.currentIndex))
        XCTAssertEqual(restored.current.exposureEV, 1)
        XCTAssertTrue(restored.canRedo)
    }

    /// (Negative zero is the one documented exception: it returns as +0.0, which `EditState ==` treats as equal.)
    func testAwkwardDoublesAndNestedValuesRoundTripExactly() throws {
        var s = EditState()
        s.exposureEV = 0.1 + 0.2
        s.contrast = 1e-7
        s.vignetteStrength = Double.pi / 10
        var mask = Mask()
        mask.kind = .radial
        mask.exposureEV = 0.30000000000000004
        s.masks = [mask]
        let archive = try XCTUnwrap(try roundTrip(history([(s, "Awkward")])))
        XCTAssertEqual(archive.entries.last?.state, s)
    }

    // MARK: - Delta encoding

    func testLaterEntriesStoreOnlyWhatChangedAndRemovedKeysAreTombstoned() throws {
        let h = history([(state { $0.exposureEV = 1 }, "Exposure"), (state { $0.exposureEV = 1; $0.contrast = 0.4 }, "Contrast")])
        let object = try XCTUnwrap(HistoryArchive(h).jsonObject())
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let first = try XCTUnwrap(entries[0]["delta"] as? [String: Any])
        let second = try XCTUnwrap(entries[1]["delta"] as? [String: Any])
        let third = try XCTUnwrap(entries[2]["delta"] as? [String: Any])
        XCTAssertGreaterThan(first.count, 5, "the first entry carries the whole object")
        XCTAssertEqual(second.count, 1, "only exposureEV changed: \(second)")
        XCTAssertEqual(third.count, 1, "only contrast changed: \(third)")
        XCTAssertNotNil(third["contrast"])
    }

    func testAKeyThatDisappearsBetweenEntriesIsRemovedOnDecode() throws {
        // `EditState` omits no keys itself, so exercise the tombstone path on a hand-built archive object.
        let a = try stateObject(state { $0.exposureEV = 1 })
        var b = a
        b["exposureEV"] = nil
        let object: [String: Any] = [
            "v": 1, "cursor": 1, "blobs": [String: String](),
            "entries": [
                ["id": UUID().uuidString, "summary": "one", "delta": a],
                ["id": UUID().uuidString, "summary": "two", "delta": ["exposureEV": ["$del": true]]],
            ],
        ]
        let archive = try XCTUnwrap(HistoryArchive.decode(object))
        XCTAssertEqual(archive.entries[0].state.exposureEV, 1)
        XCTAssertEqual(archive.entries[1].state.exposureEV, EditState().exposureEV, "a removed key falls back to the tolerant default")
        _ = b
    }

    // MARK: - Blob dedupe

    func testBigBlobsAreStoredOnceNotOncePerEntry() throws {
        var mask = Mask()
        mask.kind = .subject
        mask.subjectInstancePNGs = [Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })]
        var h = EditHistory(state { $0.masks = [mask] }, initialSummary: "Opened")
        for i in 0..<100 {
            var next = h.current
            next.masks[0].subjectInstanceEnabled = [i % 2 == 0]
            next.exposureEV = Double(i) / 100
            h.commit(next, summary: "Toggle \(i)")
        }
        XCTAssertEqual(h.entries.count, 101)
        let object = try XCTUnwrap(HistoryArchive(h).jsonObject())
        let size = try JSONSerialization.data(withJSONObject: object).count
        let base64 = (100_000 * 4 + 2) / 3
        XCTAssertLessThan(size, base64 * 2, "101 entries sharing one 100 KB mask must cost about one blob, not 101 (got \(size) bytes vs one blob = \(base64))")
        let archive = try XCTUnwrap(try roundTrip(h))
        XCTAssertEqual(archive.entries.last?.state, h.entries.last?.state)
        XCTAssertEqual(archive.entries.first?.state, h.entries.first?.state)
        // The ENCODER keeps blob bytes once too (not one string per entry): the archive-level `blobs` map has exactly one entry.
        XCTAssertEqual((object["blobs"] as? [String: String])?.count, 1)
    }

    // MARK: - Memory sharing

    /// 101 restored entries must share ONE buffer per mask blob, like the live history, not hold 101 copies.
    func testRestoredEntriesShareOneBufferPerMaskBlob() throws {
        var mask = Mask(); mask.kind = .subject
        mask.subjectInstancePNGs = [Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })]
        var h = EditHistory(state { $0.masks = [mask] }, initialSummary: "Opened")
        for i in 1...20 { var next = h.current; next.exposureEV = Double(i); h.commit(next, summary: "e\(i)") }
        let archive = try XCTUnwrap(try roundTrip(h))
        XCTAssertEqual(archive.entries.count, 21)
        let addresses = archive.entries.map { entry in
            entry.state.masks[0].subjectInstancePNGs[0].withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        }
        XCTAssertEqual(Set(addresses).count, 1, "all entries should point at the same Data storage")
        XCTAssertEqual(archive.entries.last?.state, h.entries.last?.state)
    }

    // MARK: - Failure modes: all-or-nothing

    func testCorruptOrForeignInputDecodesToNil() throws {
        let good = try XCTUnwrap(HistoryArchive(history([(state { $0.exposureEV = 1 }, "A")])).jsonObject())
        XCTAssertNil(HistoryArchive.decode("nope"))
        XCTAssertNil(HistoryArchive.decode([String: Any]()))
        var wrongVersion = good; wrongVersion["v"] = 2
        XCTAssertNil(HistoryArchive.decode(wrongVersion), "unknown version")
        var badCursor = good; badCursor["cursor"] = 99
        XCTAssertNil(HistoryArchive.decode(badCursor))
        var noEntries = good; noEntries["entries"] = [[String: Any]]()
        XCTAssertNil(HistoryArchive.decode(noEntries))
        var badID = good
        var entries = try XCTUnwrap(good["entries"] as? [[String: Any]]); entries[0]["id"] = "not-a-uuid"; badID["entries"] = entries
        XCTAssertNil(HistoryArchive.decode(badID))
        XCTAssertNotNil(HistoryArchive.decode(good), "the unmodified one still decodes")
    }

    func testADuplicatedEntryIDMakesTheWholeArchiveNil() throws {
        var object = try XCTUnwrap(HistoryArchive(history([(state { $0.exposureEV = 1 }, "A")])).jsonObject())
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[1]["id"] = entries[0]["id"]
        object["entries"] = entries
        XCTAssertNil(HistoryArchive.decode(object))
    }

    func testADanglingBlobReferenceMakesTheWholeArchiveNil() throws {
        var mask = Mask(); mask.kind = .subject
        mask.subjectInstancePNGs = [Data(repeating: 7, count: 5_000)]
        var object = try XCTUnwrap(HistoryArchive(history([(state { $0.masks = [mask] }, "Mask")])).jsonObject())
        XCTAssertFalse((object["blobs"] as? [String: String] ?? [:]).isEmpty, "precondition: a blob was extracted")
        object["blobs"] = [String: String]()
        XCTAssertNil(HistoryArchive.decode(object))
    }

    func testAnEntryThatDoesNotDecodeAsAnEditStateMakesTheWholeArchiveNil() throws {
        var object = try XCTUnwrap(HistoryArchive(history([(state { $0.exposureEV = 1 }, "A")])).jsonObject())
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        var delta = try XCTUnwrap(entries[1]["delta"] as? [String: Any])
        delta["exposureEV"] = "not a number"
        entries[1]["delta"] = delta
        object["entries"] = entries
        XCTAssertNil(HistoryArchive.decode(object))
    }

    // MARK: - Consistency rule

    func testRequiringTheCurrentStateAcceptsAMatchAndRejectsAnythingElse() throws {
        let h = history([(state { $0.exposureEV = 0.7 }, "Exposure"), (state { $0.exposureEV = 0.9 }, "More")])
        let object = try XCTUnwrap(HistoryArchive(h).jsonObject())
        XCTAssertNotNil(HistoryArchive.decode(object, requiringCurrentState: try stateObject(h.current)))
        XCTAssertNil(HistoryArchive.decode(object, requiringCurrentState: try stateObject(state { $0.exposureEV = 0.7 })), "an older entry's state is not the current one")
        XCTAssertNil(HistoryArchive.decode(object, requiringCurrentState: try stateObject(state { $0.exposureEV = 0.9; $0.contrast = 0.1 })))
        XCTAssertNotNil(HistoryArchive.decode(object, requiringCurrentState: nil), "no expectation = no check")
    }

    func testTheCursorEntryIsTheOneCheckedNotTheLastEntry() throws {
        let h = history([(state { $0.exposureEV = 1 }, "A"), (state { $0.exposureEV = 2 }, "B")], cursor: 1)
        let object = try XCTUnwrap(HistoryArchive(h).jsonObject())
        XCTAssertNotNil(HistoryArchive.decode(object, requiringCurrentState: try stateObject(state { $0.exposureEV = 1 })))
        XCTAssertNil(HistoryArchive.decode(object, requiringCurrentState: try stateObject(state { $0.exposureEV = 2 })))
    }

    // MARK: - EditHistory(restoring:)

    func testRestoringValidatesAndTrimsToTheLimit() throws {
        XCTAssertNil(EditHistory(restoring: [], currentIndex: 0))
        let entries = (0..<10).map { i in HistoryEntry(state: state { $0.exposureEV = Double(i) }, summary: "\(i)") }
        XCTAssertNil(EditHistory(restoring: entries, currentIndex: 10))
        XCTAssertNil(EditHistory(restoring: entries, currentIndex: -1))
        // cursor at the end, limit 4 => 5 entries kept (the newest), cursor re-based
        let atEnd = try XCTUnwrap(EditHistory(restoring: entries, currentIndex: 9, limit: 4))
        XCTAssertEqual(atEnd.entries.count, 5)
        XCTAssertEqual(atEnd.current.exposureEV, 9)
        XCTAssertEqual(atEnd.entries.map(\.summary), ["5", "6", "7", "8", "9"])
        // cursor mid-timeline: the redo tail is dropped first, the cursor entry survives
        let mid = try XCTUnwrap(EditHistory(restoring: entries, currentIndex: 3, limit: 4))
        XCTAssertEqual(mid.current.exposureEV, 3)
        XCTAssertEqual(mid.entries.count, 5)
        XCTAssertEqual(mid.entries.map(\.summary), ["0", "1", "2", "3", "4"])
    }

    // MARK: - Determinism and compatibility

    func testEncodingIsDeterministicAndOlderReadersIgnoreTheKey() throws {
        let h = history([(state { $0.exposureEV = 0.5 }, "Exposure"), (state { $0.exposureEV = 0.6; $0.contrast = 0.3 }, "More")])
        let a = try JSONSerialization.data(withJSONObject: XCTUnwrap(HistoryArchive(h).jsonObject()), options: .sortedKeys)
        let b = try JSONSerialization.data(withJSONObject: XCTUnwrap(HistoryArchive(h).jsonObject()), options: .sortedKeys)
        XCTAssertEqual(a, b)
        // A sidecar carrying "_history" still decodes as a plain EditState (every existing reader).
        var sidecar = try stateObject(h.current)
        sidecar[HistoryArchive.sidecarKey] = try XCTUnwrap(HistoryArchive(h).jsonObject())
        let data = try JSONSerialization.data(withJSONObject: sidecar)
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: data), h.current)
    }
}

/// The caching `Encoder`: same output as the one-shot path, but unchanged entries are never re-encoded.
final class HistoryArchiveEncoderTests: XCTestCase {
    private func bigMaskState(_ ev: Double) -> EditState {
        var mask = Mask(); mask.kind = .subject
        mask.subjectInstancePNGs = [Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })]
        var s = EditState(); s.masks = [mask]; s.exposureEV = ev
        return s
    }

    private func sorted(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    func testTheCachingEncoderProducesTheSameBytesAsTheOneShotPath() throws {
        var h = EditHistory(bigMaskState(0), initialSummary: "Opened")
        let encoder = HistoryArchive.Encoder()
        for i in 1...5 {
            var next = h.current; next.exposureEV = Double(i); h.commit(next, summary: "e\(i)")
            XCTAssertEqual(try sorted(XCTUnwrap(encoder.jsonObject(for: HistoryArchive(h)))), try sorted(XCTUnwrap(HistoryArchive(h).jsonObject())))
        }
    }

    func testASecondEncodeOfTheSameHistoryDoesNotReEncodeEntries() throws {
        var h = EditHistory(bigMaskState(0), initialSummary: "Opened")
        for i in 1...30 { var next = h.current; next.exposureEV = Double(i); h.commit(next, summary: "e\(i)") }
        let encoder = HistoryArchive.Encoder()
        let archive = HistoryArchive(h)
        let t0 = Date()
        _ = encoder.jsonObject(for: archive)
        let cold = Date().timeIntervalSince(t0)
        let t1 = Date()
        _ = encoder.jsonObject(for: archive)
        let warm = Date().timeIntervalSince(t1)
        XCTAssertLessThan(warm, cold / 4, "a warm re-encode (\(warm)s) must be a small fraction of the cold one (\(cold)s)")
    }

    func testEntriesThatLeaveTheTimelineAreDroppedFromTheCacheAndTheirBlobsFromTheArchive() throws {
        var h = EditHistory(bigMaskState(0), limit: 2, initialSummary: "Opened")
        let encoder = HistoryArchive.Encoder()
        _ = encoder.jsonObject(for: HistoryArchive(h))
        for i in 1...5 {
            var s = EditState(); s.exposureEV = Double(i) // no mask any more: the big blob only lived in the oldest entries
            h.commit(s, summary: "e\(i)")
        }
        let object = try XCTUnwrap(encoder.jsonObject(for: HistoryArchive(h)))
        XCTAssertTrue((object["blobs"] as? [String: String] ?? ["x": "y"]).isEmpty, "no remaining entry references the old mask blob")
        XCTAssertNotNil(HistoryArchive.decode(object))
    }
}
