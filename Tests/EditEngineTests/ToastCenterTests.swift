import XCTest
@testable import PhotoApp

@MainActor
final class ToastCenterTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var delays: [TimeInterval] = []
    private var fires: [@MainActor @Sendable () -> Void] = []
    private var announcements: [String] = []
    private var performed: [FeedbackAction] = []
    private var voiceOver = false

    private func makeCenter() -> ToastCenter {
        ToastCenter(hooks: ToastCenter.Hooks(
            now: { [unowned self] in clock },
            schedule: { [unowned self] delay, fire in delays.append(delay); fires.append(fire) },
            announce: { [unowned self] in announcements.append($0) },
            voiceOverOn: { [unowned self] in voiceOver },
            perform: { [unowned self] in performed.append($0) }
        ))
    }

    private let exported = Feedback(kind: .done, title: "Export", message: "Exported 2 photos.")

    func testShowAnnouncesSchedulesAndExpires() {
        let center = makeCenter()
        center.show(exported)
        XCTAssertEqual(announcements, ["Export. Exported 2 photos."])
        XCTAssertEqual(delays, [4])
        XCTAssertNotNil(center.current)
        clock = clock.addingTimeInterval(4)
        fires[0]()
        XCTAssertNil(center.current)
    }

    func testVoiceOverGetsTenSeconds() {
        voiceOver = true
        let center = makeCenter()
        center.show(exported)
        XCTAssertEqual(delays, [10])
    }

    func testHoveringKeepsTheToastPastTheOriginalFire() {
        let center = makeCenter()
        center.show(exported)
        clock = clock.addingTimeInterval(1)
        center.setHovering(true)
        clock = clock.addingTimeInterval(5)
        fires[0]()
        XCTAssertNotNil(center.current, "the stale timer must not remove a paused toast")
    }

    func testPerformActionRunsTheActionAndDismisses() throws {
        let center = makeCenter()
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        center.show(Feedback(kind: .done, title: "Export", message: "Done.", action: .revealInFinder([url])))
        let id = try XCTUnwrap(center.current).id
        center.performAction(id: id + 99)
        XCTAssertTrue(performed.isEmpty)
        XCTAssertNotNil(center.current)
        center.performAction(id: id)
        XCTAssertEqual(performed, [.revealInFinder([url])])
        XCTAssertNil(center.current)
    }

    func testANoticeIsIgnored() {
        let center = makeCenter()
        center.show(Feedback.notice("Backup", "Read this."))
        XCTAssertNil(center.current)
        XCTAssertTrue(announcements.isEmpty)
        XCTAssertTrue(delays.isEmpty)
    }

    func testAnAlertKindIsIgnored() {
        let center = makeCenter()
        center.show(Feedback.error("Export", "No."))
        XCTAssertNil(center.current)
        XCTAssertTrue(announcements.isEmpty)
        XCTAssertTrue(delays.isEmpty)
    }
}
