import XCTest
@_spi(GroovyInternal) @testable import GroovySDK

/// Spec 230 T014: the tap gate (data-model "Tap gate"): one native tap allows one external open,
/// within 5 seconds; at most four taps are kept; a decline consumes a tap; a drag, a touch released
/// outside the view and a cancelled touch are not taps.
final class TapGateTests: XCTestCase {
    func testNoTapAllowsNothing() throws {
        var gate = TapGate()
        XCTAssertFalse(gate.consume(at: 100))
        XCTAssertEqual(gate.taps, [])
    }

    func testATapAllowsOneOpenThenNoMore() throws {
        var gate = TapGate()
        gate.noteTap(at: 100)
        XCTAssertTrue(gate.consume(at: 100.5))
        XCTAssertFalse(gate.consume(at: 100.6), "one tap, one open")
    }

    func testATapOlderThanTheWindowAllowsNothing() throws {
        var gate = TapGate()
        gate.noteTap(at: 100)
        XCTAssertTrue(TapGate.tapWindow == 5)
        XCTAssertFalse(gate.consume(at: 105.01), "5 s is the window")
        gate.noteTap(at: 200)
        XCTAssertTrue(gate.consume(at: 205), "exactly 5 s is still inside it")
    }

    func testTwoTapsAllowTwoOpensAndAThirdIsRefused() throws {
        var gate = TapGate()
        gate.noteTap(at: 100)
        gate.noteTap(at: 100.3)
        XCTAssertTrue(gate.consume(at: 101))
        XCTAssertTrue(gate.consume(at: 101.1))
        XCTAssertFalse(gate.consume(at: 101.2))
    }

    func testAFifthTapDropsTheOldest() throws {
        var gate = TapGate()
        for t in [100.0, 100.1, 100.2, 100.3, 100.4] { gate.noteTap(at: t) }
        XCTAssertEqual(gate.taps, [100.1, 100.2, 100.3, 100.4])
        XCTAssertEqual(TapGate.maxTaps, 4)
    }

    func testADismissConsumesOneTap() throws {
        var gate = TapGate()
        gate.noteTap(at: 100)
        gate.consumeForMessage(at: 100.2)
        XCTAssertFalse(gate.consume(at: 100.3), "the tap declined an offer; it opens nothing")
        gate.consumeForMessage(at: 100.4)
        XCTAssertEqual(gate.taps, [], "a dismiss with no tap changes nothing")
    }

    func testAnActivationCountsAsATap() throws {
        var gate = TapGate()
        gate.noteActivation(at: 100)
        XCTAssertTrue(gate.consume(at: 100.1))
        XCTAssertFalse(gate.consume(at: 100.2))
    }

    // The recogniser's pure decision (data-model: a touch that moved beyond the slop, or ended
    // outside the view, is not a tap; a cancelled touch never reaches it).

    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 100)

    func testATouchThatStaysPutInsideTheViewIsATap() throws {
        XCTAssertTrue(TapGate.isTap(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 14, y: 12), bounds: bounds, slop: 10))
    }

    func testAMovedTouchIsNotATap() throws {
        XCTAssertFalse(TapGate.isTap(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 10, y: 40), bounds: bounds, slop: 10), "a scroll through the view")
        XCTAssertFalse(TapGate.isTap(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 10), bounds: bounds, slop: 10))
        XCTAssertTrue(TapGate.isTap(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 20, y: 10), bounds: bounds, slop: 10), "the slop itself is allowed")
    }

    func testATouchEndingOutsideTheViewIsNotATap() throws {
        XCTAssertFalse(TapGate.isTap(start: CGPoint(x: 298, y: 98), end: CGPoint(x: 305, y: 104), bounds: bounds, slop: 10))
        XCTAssertFalse(TapGate.isTap(start: CGPoint(x: 2, y: 2), end: CGPoint(x: -3, y: 2), bounds: bounds, slop: 10))
    }

    // Spec 230 T046 (the CTO's decision on PR 976 for #978): the observer's bookkeeping, pure. A
    // second finger, in the same event or a later one, makes the sequence no tap; a reset recovers.

    func testAPlainTapIsATap() throws {
        var sequence = TapSequence()
        XCTAssertTrue(sequence.began(touches: 1, at: CGPoint(x: 10, y: 10)))
        XCTAssertTrue(sequence.moved(to: CGPoint(x: 12, y: 11), slop: 10))
        XCTAssertTrue(sequence.ended(at: CGPoint(x: 13, y: 12), bounds: bounds, slop: 10))
    }

    func testASecondFingerInALaterEventIsNoTap() throws {
        var sequence = TapSequence()
        XCTAssertTrue(sequence.began(touches: 1, at: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(sequence.began(touches: 1, at: CGPoint(x: 200, y: 50)), "the second finger fails the sequence")
        XCTAssertFalse(sequence.moved(to: CGPoint(x: 10, y: 10), slop: 10))
        XCTAssertFalse(sequence.ended(at: CGPoint(x: 10, y: 10), bounds: bounds, slop: 10), "the still first finger lifting is no tap")
    }

    func testTwoFingersInOneEventAreNoTap() throws {
        var sequence = TapSequence()
        XCTAssertFalse(sequence.began(touches: 2, at: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(sequence.ended(at: CGPoint(x: 10, y: 10), bounds: bounds, slop: 10))
    }

    func testADragIsNoTapAndStaysFailed() throws {
        var sequence = TapSequence()
        XCTAssertTrue(sequence.began(touches: 1, at: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(sequence.moved(to: CGPoint(x: 10, y: 40), slop: 10))
        XCTAssertFalse(sequence.moved(to: CGPoint(x: 10, y: 10), slop: 10), "coming back does not undo the drag")
        XCTAssertFalse(sequence.ended(at: CGPoint(x: 10, y: 10), bounds: bounds, slop: 10))
    }

    func testAPlainTapAfterAFailedSequenceIsATapOnceReset() throws {
        var sequence = TapSequence()
        _ = sequence.began(touches: 1, at: CGPoint(x: 10, y: 10))
        _ = sequence.began(touches: 1, at: CGPoint(x: 200, y: 50))
        XCTAssertFalse(sequence.began(touches: 1, at: CGPoint(x: 10, y: 10)), "without a reset the failure holds")
        sequence.reset()
        XCTAssertEqual(sequence, TapSequence())
        XCTAssertTrue(sequence.began(touches: 1, at: CGPoint(x: 10, y: 10)))
        XCTAssertTrue(sequence.ended(at: CGPoint(x: 10, y: 10), bounds: bounds, slop: 10))
    }

    func testAnEndWithoutABeginIsNoTap() throws {
        XCTAssertFalse(TapSequence().ended(at: CGPoint(x: 10, y: 10), bounds: bounds, slop: 10))
    }

    func testTheObserverNeverTakesTheTouches() throws {
        let observer = TapObserver { _ in }
        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        XCTAssertTrue(observer.gestureRecognizer(observer, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))
        XCTAssertEqual(TapObserver.slop, 10)
    }
}
