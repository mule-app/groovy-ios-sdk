import UIKit

/// Spec 230 — the tap gate (data-model "Tap gate"): an external page opens only after a native
/// touch ended inside the view, one open per tap, within `tapWindow`. Fed by `TapObserver`, read by
/// the navigation rule through `GroovyWidgetView.decide`. Pure, so every rule is unit-tested; the
/// Android SDK implements the same gate (`TapGate.kt`).
struct TapGate: Equatable {
    /// How long a tap allows an open (the browsers' own notion of a recent gesture; covers the
    /// widget's click-token fetch). Spec 230 research R1.
    static let tapWindow: TimeInterval = 5
    /// The queue's bound: a tap storm cannot grow it, and at most this many opens follow.
    static let maxTaps = 4

    /// The moments (monotonic clock) of the unconsumed taps, oldest first.
    private(set) var taps: [TimeInterval] = []

    /// A tap ended inside the view at `now`.
    mutating func noteTap(at now: TimeInterval) {
        expire(at: now)
        if taps.count >= Self.maxTaps { taps.removeFirst() }
        taps.append(now)
    }

    /// Whether an unconsumed tap of the last `tapWindow` exists; consumes the oldest when it does.
    mutating func consume(at now: TimeInterval) -> Bool {
        expire(at: now)
        guard !taps.isEmpty else { return false }
        taps.removeFirst()
        return true
    }

    /// A `groovy:dismiss` arrived: the tap declined an offer and opens nothing. Not for expand or
    /// collapse (the first collapse fires on render with no tap, and either can arrive while a real
    /// tap waits for its token).
    mutating func consumeForMessage(at now: TimeInterval) {
        _ = consume(at: now)
    }

    /// Spec 230 plan §17 question 3 (the CTO's answer A): while a screen reader or switch access
    /// is running, the widget's `groovy:click` counts as a tap. The caller checks that assistive
    /// technology is running, and holds the open that came just before the click (data-model).
    mutating func noteActivation(at now: TimeInterval) {
        noteTap(at: now)
    }

    private mutating func expire(at now: TimeInterval) {
        taps.removeAll { now - $0 > Self.tapWindow }
    }

    /// The recogniser's decision, pure: a touch is a tap when it did not move beyond `slop` from
    /// where it began and ended inside the view's bounds. A drag (a scroll through the view) and a
    /// touch released outside the view are not taps.
    static func isTap(start: CGPoint, end: CGPoint, bounds: CGRect, slop: CGFloat) -> Bool {
        abs(end.x - start.x) <= slop && abs(end.y - start.y) <= slop && bounds.contains(end)
    }
}

/// The observer's bookkeeping for one touch sequence, pure so the second-finger cases are unit
/// cases (data-model "Tap gate"; the CTO's decision on PR 976 for #978). The first touch is the
/// one judged: a `began` while a touch is tracked (a second finger in a later event), or one that
/// brings more than one touch (two fingers at once), fails the sequence for good; a move beyond
/// the slop fails it; `ended` is a tap only for a sequence that never failed.
struct TapSequence: Equatable {
    private(set) var start: CGPoint?
    private(set) var failed = false

    /// `touchesBegan`: `touches` is how many touches that event delivered to the recogniser (never
    /// `event.allTouches`, which holds fingers resting on other views). False when the sequence is
    /// no tap any more.
    mutating func began(touches: Int, at point: CGPoint) -> Bool {
        guard !failed, start == nil, touches == 1 else {
            failed = true
            return false
        }
        start = point
        return true
    }

    /// `touchesMoved`: false once the touch has moved beyond `slop` (a drag).
    mutating func moved(to point: CGPoint, slop: CGFloat) -> Bool {
        guard !failed, let start else { return false }
        if abs(point.x - start.x) > slop || abs(point.y - start.y) > slop {
            failed = true
            return false
        }
        return true
    }

    /// `touchesEnded`: whether the sequence was a tap (data-model: within the slop, inside the bounds).
    func ended(at point: CGPoint, bounds: CGRect, slop: CGFloat) -> Bool {
        guard !failed, let start else { return false }
        return TapGate.isTap(start: start, end: point, bounds: bounds, slop: slop)
    }

    /// The recogniser's `reset()`: a failed sequence never outlives its touches.
    mutating func reset() {
        start = nil
        failed = false
    }
}

/// Watches the touches the WebView handles without taking any of them: on an ancestor of the
/// WebView, with `cancelsTouchesInView` off and no delays, it sees every touch sequence hit-tested
/// to the view, records the moment a tap ends inside the view's bounds, and fails at once so it
/// never recognises anything itself (data-model "Tap gate"). The decisions are `TapSequence`'s.
final class TapObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// Movement beyond this (points) makes the touch a drag, not a tap.
    static let slop: CGFloat = 10

    private let onTap: (TimeInterval) -> Void
    private var tracked: UITouch?
    private var sequence = TapSequence()

    init(onTap: @escaping (TimeInterval) -> Void) {
        self.onTap = onTap
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, let view else { return }
        // The first touch of the sequence is the one judged; a second finger, in this event or a
        // later one, makes the sequence no tap.
        guard sequence.began(touches: touches.count, at: touch.location(in: view)) else {
            state = .failed
            return
        }
        tracked = touch
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let tracked, touches.contains(tracked), let view else { return }
        if !sequence.moved(to: tracked.location(in: view), slop: Self.slop) {
            // A drag: not a tap. Failing now leaves the WebView's own recognisers untouched.
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        defer { state = .failed }
        guard let tracked, touches.contains(tracked), let view else { return }
        if sequence.ended(at: tracked.location(in: view), bounds: view.bounds, slop: Self.slop) {
            onTap(ProcessInfo.processInfo.systemUptime)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .failed
    }

    override func reset() {
        super.reset()
        tracked = nil
        sequence.reset()
    }

    /// Never in the way of the WebView's own recognisers.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
