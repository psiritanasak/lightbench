import XCTest
@testable import PhotoApp

/// `ThinSliderDrag`'s pure press / drag rules and `ThinSliderGeometry.keyed`'s fine step. Track: width 205, thumb 5 (usable 200),
/// range 0...100, so one point of pointer travel is 0.5 of a value.
final class ThinSliderDragTests: XCTestCase {
    private let track = ThinSliderDrag.Track(width: 205, thumbWidth: 5, range: 0...100)
    private let accuracy = 0.0001

    private func begin(
        x: Double = 52.5, value: Double = 25, clicks: Int = 1, option: Bool = false, canReset: Bool
    ) -> (ThinSliderDrag, ThinSliderDrag.Start) {
        ThinSliderDrag.begin(x: x, value: value, clickCount: clicks, optionHeld: option, canReset: canReset, track: track)
    }

    // MARK: - resettable press

    func testResettablePressWritesNothing() {
        let (_, start) = begin(canReset: true)
        XCTAssertEqual(start, .none)
    }

    func testResettableSmallMoveWritesNothingAndThresholdMoveWrites() {
        var (drag, _) = begin(x: 52.5, canReset: true)
        XCTAssertNil(drag.move(toX: 54.5, optionHeld: false, track: track))
        XCTAssertNil(drag.move(toX: 50.5, optionHeld: false, track: track))
        let written = drag.move(toX: 55.5, optionHeld: false, track: track)
        XCTAssertEqual(try XCTUnwrap(written), track.absolute(atX: 55.5), accuracy: accuracy)
    }

    func testResettableAfterThresholdTracksAbsolute() {
        var (drag, _) = begin(x: 52.5, canReset: true)
        _ = drag.move(toX: 60, optionHeld: false, track: track)
        let written = drag.move(toX: 102.5, optionHeld: false, track: track)
        XCTAssertEqual(try XCTUnwrap(written), track.absolute(atX: 102.5), accuracy: accuracy)
    }

    // MARK: - non-resettable press (today's behaviour)

    func testNonResettablePressWritesAbsoluteAtPress() {
        let (drag, start) = begin(x: 102.5, canReset: false)
        XCTAssertEqual(start, .write(track.absolute(atX: 102.5)))
        XCTAssertEqual(drag.mode, .absolute)
        XCTAssertEqual(track.absolute(atX: 102.5), 50, accuracy: accuracy)
    }

    func testNonResettableDoubleClickIsANormalPress() {
        let (_, start) = begin(x: 102.5, clicks: 2, canReset: false)
        XCTAssertEqual(start, .write(track.absolute(atX: 102.5)))
    }

    func testNonResettableMoveTracksAbsolute() {
        var (drag, _) = begin(x: 102.5, canReset: false)
        let written = drag.move(toX: 152.5, optionHeld: false, track: track)
        XCTAssertEqual(try XCTUnwrap(written), 75, accuracy: accuracy)
    }

    // MARK: - double-click

    func testResettableDoubleClickResetsAndIgnoresTheRestOfThePress() {
        var (drag, start) = begin(clicks: 2, canReset: true)
        XCTAssertEqual(start, .reset)
        XCTAssertEqual(drag.mode, .consumed)
        XCTAssertNil(drag.move(toX: 150, optionHeld: false, track: track))
        XCTAssertNil(drag.move(toX: 160, optionHeld: true, track: track))
    }

    // MARK: - option (fine)

    func testOptionAtPressWritesNothingThenMovesAQuarterSpeed() {
        for canReset in [true, false] {
            var (drag, start) = begin(x: 102.5, value: 50, option: true, canReset: canReset)
            XCTAssertEqual(start, .none)
            let written = drag.move(toX: 142.5, optionHeld: true, track: track)
            XCTAssertEqual(try XCTUnwrap(written), 50 + 40 * 100 / 200 / 4, accuracy: accuracy)
        }
    }

    func testOptionReleasedMidDragContinuesWithoutJumpThenMovesOneToOne() throws {
        var (drag, _) = begin(x: 102.5, value: 50, option: true, canReset: true)
        let atSwitch = try XCTUnwrap(drag.move(toX: 142.5, optionHeld: true, track: track))
        XCTAssertEqual(atSwitch, 55, accuracy: accuracy)
        // Released with the pointer at the same x: nothing changes.
        XCTAssertNil(drag.move(toX: 142.5, optionHeld: false, track: track))
        XCTAssertEqual(drag.lastValue, atSwitch)
        let after = try XCTUnwrap(drag.move(toX: 152.5, optionHeld: false, track: track))
        XCTAssertEqual(after, atSwitch + 10 * 100 / 200, accuracy: accuracy)
    }

    func testOptionPressedDuringAbsoluteTrackingDoesNotJumpThenIsFine() throws {
        var (drag, _) = begin(x: 102.5, canReset: false)
        let a = try XCTUnwrap(drag.move(toX: 122.5, optionHeld: false, track: track))
        XCTAssertEqual(a, 60, accuracy: accuracy)
        XCTAssertNil(drag.move(toX: 122.5, optionHeld: true, track: track))
        let b = try XCTUnwrap(drag.move(toX: 162.5, optionHeld: true, track: track))
        XCTAssertEqual(b, 60 + 40 * 100 / 200 / 4, accuracy: accuracy)
    }

    func testOptionPressedWhilePendingIsFineFromThePressValue() throws {
        var (drag, _) = begin(x: 102.5, value: 50, canReset: true)
        let written = try XCTUnwrap(drag.move(toX: 142.5, optionHeld: true, track: track))
        XCTAssertEqual(written, 55, accuracy: accuracy)
    }

    func testOptionPressedAfterAbsoluteStaysRelativeOnRelease() throws {
        // Once Option was used the drag does not snap back to the pointer's absolute value.
        var (drag, _) = begin(x: 102.5, canReset: false)
        _ = drag.move(toX: 122.5, optionHeld: true, track: track)
        let released = drag.move(toX: 132.5, optionHeld: false, track: track)
        let expected: Double = 52.5 + 5
        XCTAssertEqual(try XCTUnwrap(released), expected, accuracy: accuracy)
    }

    // MARK: - clamping and degenerate cases

    func testRelativeClampsAtBothEnds() throws {
        var (drag, _) = begin(x: 102.5, value: 99, option: true, canReset: true)
        XCTAssertEqual(try XCTUnwrap(drag.move(toX: 2_000, optionHeld: true, track: track)), 100, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(drag.move(toX: -2_000, optionHeld: true, track: track)), 0, accuracy: accuracy)
    }

    func testUnusableTrackWritesNothingInRelativeMode() {
        let flat = ThinSliderDrag.Track(width: 5, thumbWidth: 5, range: 0...100)
        var (drag, _) = ThinSliderDrag.begin(
            x: 0, value: 40, clickCount: 1, optionHeld: true, canReset: true, track: flat
        )
        XCTAssertNil(drag.move(toX: 30, optionHeld: true, track: flat))
    }

    func testUnchangedValueReturnsNil() {
        var (drag, _) = begin(x: 102.5, canReset: false)
        XCTAssertNil(drag.move(toX: 102.5, optionHeld: false, track: track))
    }

    // MARK: - keyed fine

    func testKeyedFineIsAQuarterStep() {
        XCTAssertEqual(ThinSliderGeometry.keyed(50, key: .increase, coarse: false, fine: true, in: 0...100), 51.25, accuracy: accuracy)
        XCTAssertEqual(ThinSliderGeometry.keyed(50, key: .decrease, coarse: false, fine: true, in: 0...100), 48.75, accuracy: accuracy)
    }

    func testKeyedCoarseAndFineTogetherIsOneStep() {
        XCTAssertEqual(ThinSliderGeometry.keyed(50, key: .increase, coarse: true, fine: true, in: 0...100), 55, accuracy: accuracy)
    }

    func testKeyedFineDoesNotAffectHomeEnd() {
        XCTAssertEqual(ThinSliderGeometry.keyed(50, key: .minimum, coarse: false, fine: true, in: 0...100), 0, accuracy: accuracy)
        XCTAssertEqual(ThinSliderGeometry.keyed(50, key: .maximum, coarse: false, fine: true, in: 0...100), 100, accuracy: accuracy)
    }
}
