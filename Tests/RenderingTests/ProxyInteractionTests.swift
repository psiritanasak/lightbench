import XCTest
@testable import PhotoApp

final class ProxyInteractionTests: XCTestCase {
    func testSingleChangeNeverInteracts() {
        var interaction = ProxyInteraction()
        interaction.noteEditStateChanged()
        XCTAssertFalse(interaction.isInteracting)
    }

    func testSecondChangeEngagesInteraction() {
        var interaction = ProxyInteraction()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        XCTAssertTrue(interaction.isInteracting)
    }

    func testThirdAndLaterChangesStayInteracting() {
        var interaction = ProxyInteraction()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        XCTAssertTrue(interaction.isInteracting)
    }

    func testSettleReturnsFalseWhenBurstNeverUsedProxy() {
        // A burst that never actually engaged the proxy (small photo, or
        // already-full-res every frame) must not trigger an extra full-res
        // redraw after settling — that would be a straight regression
        // against today's behavior of one redraw per change.
        var interaction = ProxyInteraction()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        interaction.recordFrame(usedProxy: false)

        XCTAssertFalse(interaction.settle())
    }

    func testSettleReturnsTrueWhenBurstUsedProxy() {
        var interaction = ProxyInteraction()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        interaction.recordFrame(usedProxy: true)

        XCTAssertTrue(interaction.settle())
    }

    func testSettleResetsTheCounter() {
        var interaction = ProxyInteraction()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        interaction.recordFrame(usedProxy: true)
        _ = interaction.settle()

        XCTAssertEqual(interaction.observedEditChanges, 0)
        XCTAssertFalse(interaction.isInteracting)
        XCTAssertFalse(interaction.lastFrameUsedProxy)
    }

    func testBurstsSeparatedBySettleDoNotAccumulate() {
        var interaction = ProxyInteraction()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        _ = interaction.settle()

        // A fresh single change after a settle must NOT be interacting —
        // if the counter leaked across the settle boundary, one more change
        // here would wrongly read as the burst's "2nd" change.
        interaction.noteEditStateChanged()
        XCTAssertFalse(interaction.isInteracting)
    }

    func testResetClearsEverythingRegardlessOfState() {
        var interaction = ProxyInteraction()
        interaction.noteEditStateChanged()
        interaction.noteEditStateChanged()
        interaction.recordFrame(usedProxy: true)

        interaction.reset()

        XCTAssertEqual(interaction.observedEditChanges, 0)
        XCTAssertFalse(interaction.isInteracting)
        XCTAssertFalse(interaction.lastFrameUsedProxy)
    }

    func testRecordFrameTracksMostRecentValue() {
        var interaction = ProxyInteraction()
        interaction.recordFrame(usedProxy: true)
        XCTAssertTrue(interaction.lastFrameUsedProxy)
        interaction.recordFrame(usedProxy: false)
        XCTAssertFalse(interaction.lastFrameUsedProxy)
    }
}
