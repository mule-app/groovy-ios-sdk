import XCTest
@_spi(GroovyInternal) @testable import GroovySDK

/// T027: the view's state machine (data-model "Widget view state").
final class WidgetStateTests: XCTestCase {
    typealias M = WidgetStateMachine

    /// A machine that has loaded and committed generation 1, at `initial`.
    private func committed(initial: CGFloat = 0) -> M {
        var m = M()
        m.initialHeight = initial
        _ = m.handle(.load)
        _ = m.handle(.navigationCommitted(generation: 1))
        return m
    }

    /// A machine waiting for content after the first ready.
    private func waiting(initial: CGFloat = 0) -> M {
        var m = committed(initial: initial)
        _ = m.handle(.message(.ready(height: 0, bridge: 1), generation: 1))
        return m
    }

    private func showing(_ h: CGFloat) -> M {
        var m = waiting()
        _ = m.handle(.message(.resize(height: h, loading: false), generation: 1))
        return m
    }

    private func emitted(_ effects: [M.Effect]) -> [GroovyWidgetEvent] {
        effects.compactMap { if case .emit(let e) = $0 { return e } else { return nil } }
    }

    func testLoadStartsAtTheInitialHeightAndArmsTheReadyTimer() throws {
        var m = M()
        m.initialHeight = 120
        let effects = m.handle(.load)
        XCTAssertEqual(m.state, .loading)
        XCTAssertEqual(m.generation, 1)
        XCTAssertEqual(m.height, 120)
        XCTAssertTrue(effects.contains(.setHeight(120)))
        XCTAssertTrue(effects.contains(.loadPage(generation: 1, newWebView: false)))
        XCTAssertTrue(effects.contains(.startTimer(.ready, generation: 1)))
    }

    func testFirstReadySendsTheContextAndArmsTheContentTimer() throws {
        var m = committed(initial: 120)
        let effects = m.handle(.message(.ready(height: 907, bridge: 1), generation: 1))
        XCTAssertEqual(m.state, .waiting)
        XCTAssertTrue(effects.contains(.sendContext))
        XCTAssertTrue(effects.contains(.startTimer(.content, generation: 1)))
        // The ready's height is the loader's: never shown.
        XCTAssertEqual(m.height, 120)
        XCTAssertFalse(effects.contains(.setHeight(907)))
    }

    func testOnlyTheFirstReadyIsAnswered() throws {
        var m = waiting()
        let effects = m.handle(.message(.ready(height: 0, bridge: 1), generation: 1))
        XCTAssertFalse(effects.contains(.sendContext))
    }

    func testDropsMessagesBeforeTheNavigationCommits() throws {
        var m = M()
        _ = m.handle(.load)
        XCTAssertEqual(m.handle(.message(.ready(height: 0, bridge: 1), generation: 1)), [])
        XCTAssertEqual(m.state, .loading)
    }

    func testDropsMessagesOfAnotherGeneration() throws {
        var m = waiting()
        XCTAssertEqual(m.handle(.message(.resize(height: 200, loading: false), generation: 0)), [])
        XCTAssertEqual(m.handle(.timerFired(.ready, generation: 0)), [])
        XCTAssertEqual(m.handle(.timerFired(.content, generation: 7)), [])
        XCTAssertEqual(m.state, .waiting)
    }

    func testLoadingHeightsNeverShowInAnyState() throws {
        var m = committed(initial: 80)
        XCTAssertFalse(m.handle(.message(.resize(height: 907, loading: true), generation: 1)).contains(.setHeight(907)))
        _ = m.handle(.message(.ready(height: 0, bridge: 1), generation: 1))
        _ = m.handle(.message(.resize(height: 907, loading: true), generation: 1))
        XCTAssertEqual(m.state, .waiting)
        XCTAssertEqual(m.height, 80)
        _ = m.handle(.message(.resize(height: 250, loading: false), generation: 1))
        _ = m.handle(.message(.resize(height: 907, loading: true), generation: 1))
        XCTAssertEqual(m.state, .showing(250))
    }

    func testFirstContentEmitsLoadedThenResized() throws {
        var m = waiting()
        var effects = m.handle(.message(.resize(height: 250, loading: false), generation: 1))
        XCTAssertEqual(emitted(effects), [.loaded(250)])
        XCTAssertTrue(effects.contains(.setHeight(250)))
        XCTAssertTrue(effects.contains(.cancelTimer(.content)))
        effects = m.handle(.message(.expand(height: 300), generation: 1))
        XCTAssertEqual(emitted(effects), [.resized(300)])
        effects = m.handle(.message(.collapse(height: 300), generation: 1))
        XCTAssertEqual(emitted(effects), [])
        // A height of 0 is never content.
        effects = m.handle(.message(.resize(height: 0, loading: false), generation: 1))
        XCTAssertEqual(m.state, .showing(300))
    }

    func testEmptyCollapsesAndReports() throws {
        var m = showing(250)
        let effects = m.handle(.message(.empty(reason: "no_fill"), generation: 1))
        XCTAssertEqual(m.state, .empty(.widget(.noFill)))
        XCTAssertEqual(m.height, 0)
        XCTAssertTrue(effects.contains(.setHeight(0)))
        XCTAssertEqual(emitted(effects), [.empty(.noFill)])
    }

    func testUnknownEmptyReasonIsError() throws {
        var m = waiting()
        XCTAssertEqual(emitted(m.handle(.message(.empty(reason: "brand-new"), generation: 1))), [.empty(.error)])
        var a = waiting()
        XCTAssertEqual(emitted(a.handle(.message(.empty(reason: "account_rejected"), generation: 1))), [.empty(.accountRejected)])
    }

    func testContextAfterNoFillWaitsAtZero() throws {
        var m = waiting(initial: 120)
        _ = m.handle(.message(.empty(reason: "no_fill"), generation: 1))
        let effects = m.handle(.contextChanged)
        XCTAssertEqual(m.state, .waiting)
        XCTAssertEqual(m.height, 0)
        XCTAssertTrue(effects.contains(.sendContext))
        XCTAssertTrue(effects.contains(.startTimer(.content, generation: 1)))
        // This generation never showed content, so its first content still reports `loaded`.
        XCTAssertEqual(emitted(m.handle(.message(.resize(height: 200, loading: false), generation: 1))), [.loaded(200)])
    }

    func testContextAfterLoadFailureReloadsAtZero() throws {
        var m = committed(initial: 120)
        _ = m.handle(.loadFailed(generation: 1))
        XCTAssertEqual(m.state, .empty(.loadFailed))
        let effects = m.handle(.contextChanged)
        XCTAssertEqual(m.generation, 2)
        XCTAssertEqual(m.state, .loading)
        XCTAssertEqual(m.height, 0)
        XCTAssertTrue(effects.contains(.loadPage(generation: 2, newWebView: false)))

        var t = committed(initial: 120)
        _ = t.handle(.timerFired(.ready, generation: 1))
        XCTAssertEqual(t.state, .empty(.readyTimeout))
        XCTAssertEqual(emitted(t.handle(.contextChanged)), [])
        XCTAssertEqual(t.generation, 2)
    }

    func testTheSameEmptyIsReportedOnce() throws {
        var m = waiting()
        XCTAssertEqual(emitted(m.handle(.message(.empty(reason: "account_rejected"), generation: 1))), [.empty(.accountRejected)])
        _ = m.handle(.contextChanged)
        XCTAssertEqual(emitted(m.handle(.message(.empty(reason: "account_rejected"), generation: 1))), [])
        // A different reason is a change.
        XCTAssertEqual(emitted(m.handle(.message(.empty(reason: "error"), generation: 1))), [.empty(.error)])
    }

    func testContextAfterAccountRejectedStaysEmpty() throws {
        var m = waiting()
        _ = m.handle(.message(.empty(reason: "account_rejected"), generation: 1))
        let effects = m.handle(.contextChanged)
        XCTAssertEqual(m.state, .empty(.widget(.accountRejected)))
        XCTAssertTrue(effects.contains(.sendContext))
        XCTAssertFalse(effects.contains { if case .startTimer = $0 { return true } else { return false } })
    }

    func testContextWhileShowingSendsWithoutATimer() throws {
        var m = showing(250)
        let effects = m.handle(.contextChanged)
        XCTAssertEqual(effects.filter { $0 == .sendContext }.count, 1)
        XCTAssertFalse(effects.contains { if case .startTimer = $0 { return true } else { return false } })
        XCTAssertEqual(m.state, .showing(250))
        // While loading or idle, the context goes with the ready.
        var l = committed()
        XCTAssertFalse(l.handle(.contextChanged).contains(.sendContext))
    }

    func testReadyTimeoutAndContentTimeout() throws {
        var m = committed(initial: 50)
        XCTAssertEqual(emitted(m.handle(.timerFired(.ready, generation: 1))), [.empty(.timeout)])
        XCTAssertEqual(m.height, 0)

        var w = waiting()
        XCTAssertEqual(emitted(w.handle(.timerFired(.content, generation: 1))), [.empty(.timeout)])
        XCTAssertEqual(w.state, .empty(.contentTimeout))
        // A content timer never collapses a shown ad.
        var s = showing(250)
        XCTAssertEqual(s.handle(.timerFired(.content, generation: 1)), [])
        XCTAssertEqual(s.state, .showing(250))
        // A late fill after a timeout shows.
        XCTAssertEqual(emitted(w.handle(.message(.resize(height: 220, loading: false), generation: 1))), [.loaded(220)])
    }

    func testUnsupportedBridgeStopsAtOnceAtZero() throws {
        var m = committed(initial: 120)
        let effects = m.handle(.unsupportedBridge(2, generation: 1))
        XCTAssertEqual(m.state, .empty(.unsupported))
        XCTAssertEqual(m.height, 0)
        XCTAssertEqual(emitted(effects), [.empty(.unsupported)])
        XCTAssertTrue(effects.contains(.cancelTimer(.ready)))
        XCTAssertEqual(m.handle(.contextChanged), [])
    }

    func testRendererLossHoldsTheHeightThenCollapses() throws {
        var m = showing(250)
        var effects = m.handle(.rendererLost)
        XCTAssertEqual(m.state, .loading)
        XCTAssertEqual(m.height, 250)
        XCTAssertTrue(effects.contains(.loadPage(generation: 2, newWebView: true)))
        _ = m.handle(.navigationCommitted(generation: 2))
        effects = m.handle(.rendererLost)
        XCTAssertEqual(m.state, .empty(.rendererLost))
        XCTAssertEqual(m.height, 0)
        XCTAssertEqual(emitted(effects), [.empty(.error)])

        var e = waiting(initial: 0)
        _ = e.handle(.message(.empty(reason: "no_fill"), generation: 1))
        _ = e.handle(.rendererLost)
        XCTAssertEqual(e.height, 0)
    }

    func testOnlyRendererLossesInARowCollapse() throws {
        // Two losses far apart (the app backgrounded twice) each reload, since content showed between.
        var m = showing(250)
        _ = m.handle(.rendererLost)
        _ = m.handle(.navigationCommitted(generation: 2))
        _ = m.handle(.message(.ready(height: 0, bridge: 1), generation: 2))
        _ = m.handle(.message(.resize(height: 250, loading: false), generation: 2))
        let effects = m.handle(.rendererLost)
        XCTAssertEqual(m.state, .loading)
        XCTAssertTrue(effects.contains(.loadPage(generation: 3, newWebView: true)))
    }

    func testConfigurationChangeStartsAtTheNewInitialHeight() throws {
        var m = showing(250)
        m.initialHeight = 90
        let effects = m.handle(.load)
        XCTAssertEqual(m.generation, 2)
        XCTAssertEqual(m.state, .loading)
        XCTAssertEqual(m.height, 90)
        XCTAssertTrue(effects.contains(.loadPage(generation: 2, newWebView: false)))
        // The new generation reports loaded again.
        _ = m.handle(.navigationCommitted(generation: 2))
        _ = m.handle(.message(.ready(height: 0, bridge: 1), generation: 2))
        XCTAssertEqual(emitted(m.handle(.message(.resize(height: 260, loading: false), generation: 2))), [.loaded(260)])
    }

    func testInitialHeightChangeAppliesFromTheNextGeneration() throws {
        var m = waiting(initial: 100)
        m.initialHeight = 300
        XCTAssertEqual(m.height, 100)
    }

    func testOfferOpenedCarriesTheLastClickEventId() throws {
        // The widget opens the offer in the same task as its click, so the open usually comes
        // first: the offer waits for its click (research R6).
        var m = showing(250)
        var effects = m.handle(.offerOpened)
        XCTAssertEqual(emitted(effects), [])
        XCTAssertTrue(effects.contains(.startTimer(.offerPairing, generation: 1)))
        effects = m.handle(.message(.click(eventId: "e-1"), generation: 1))
        XCTAssertEqual(emitted(effects), [.offerOpened(eventId: "e-1")])
        XCTAssertTrue(effects.contains(.cancelTimer(.offerPairing)))

        // A click that arrived first is used once.
        _ = m.handle(.message(.click(eventId: "e-2"), generation: 1))
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [.offerOpened(eventId: "e-2")])
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [])

        // No click within the pairing window: reported with an empty id.
        XCTAssertEqual(emitted(m.handle(.timerFired(.offerPairing, generation: 1))), [.offerOpened(eventId: "")])
        XCTAssertEqual(emitted(m.handle(.message(.click(eventId: "late"), generation: 1))), [])
    }

    func testARefusedOpenConsumesItsClick() throws {
        // Tap B while a sheet is up: its open is refused, then its click arrives.
        var m = showing(250)
        XCTAssertEqual(emitted(m.handle(.offerRefused)), [])
        XCTAssertEqual(emitted(m.handle(.message(.click(eventId: "B"), generation: 1))), [])
        // Tap C later pairs with its own click, not B's.
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [])
        XCTAssertEqual(emitted(m.handle(.message(.click(eventId: "C"), generation: 1))), [.offerOpened(eventId: "C")])

        // A refused open whose click came first drops that click.
        _ = m.handle(.message(.click(eventId: "D"), generation: 1))
        XCTAssertEqual(emitted(m.handle(.offerRefused)), [])
        XCTAssertEqual(m.unpairedClicks, [])
    }

    func testAnUnusedClickExpires() throws {
        var m = showing(250)
        let effects = m.handle(.message(.click(eventId: "lonely"), generation: 1))
        XCTAssertTrue(effects.contains(.startTimer(.clickExpiry, generation: 1)))
        _ = m.handle(.timerFired(.clickExpiry, generation: 1))
        XCTAssertEqual(m.unpairedClicks, [])
        _ = m.handle(.offerOpened)
        XCTAssertEqual(emitted(m.handle(.timerFired(.offerPairing, generation: 1))), [.offerOpened(eventId: "")])
    }

    func testRendererLossesNeverStrandTheViewOrReloadAnUnsupportedOne() throws {
        // Two background kills with no content between, then a new context: it reloads again.
        var m = waiting()
        _ = m.handle(.message(.empty(reason: "no_fill"), generation: 1))
        _ = m.handle(.rendererLost)
        _ = m.handle(.navigationCommitted(generation: 2))
        _ = m.handle(.message(.ready(height: 0, bridge: 1), generation: 2))
        // The reload finds no fill again: not reported a second time.
        XCTAssertEqual(emitted(m.handle(.message(.empty(reason: "no_fill"), generation: 2))), [])
        _ = m.handle(.rendererLost)
        XCTAssertEqual(m.state, .empty(.rendererLost))
        let effects = m.handle(.contextChanged)
        XCTAssertEqual(m.state, .loading)
        XCTAssertTrue(effects.contains(.loadPage(generation: 3, newWebView: true)))

        // Re-attach recovers too.
        var r = showing(250)
        _ = r.handle(.rendererLost)
        _ = r.handle(.rendererLost)
        XCTAssertEqual(r.state, .empty(.rendererLost))
        XCTAssertTrue(r.handle(.attachedToWindow).contains(.loadPage(generation: 3, newWebView: true)))

        // An unsupported widget is never loaded again, not even after a renderer loss.
        var u = committed()
        _ = u.handle(.unsupportedBridge(2, generation: 1))
        XCTAssertEqual(u.handle(.rendererLost), [])
        XCTAssertEqual(u.state, .empty(.unsupported))
    }

    func testOverlappingTapsPairInTapOrderWhenClicksComeFirst() throws {
        // Token fetched before each open: click(A), click(B), open(A), open(B).
        var m = showing(250)
        _ = m.handle(.message(.click(eventId: "A"), generation: 1))
        _ = m.handle(.message(.click(eventId: "B"), generation: 1))
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [.offerOpened(eventId: "A")])
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [.offerOpened(eventId: "B")])
        XCTAssertEqual(m.unpairedClicks, [])

        // B refused while A's sheet is up: A keeps its own id, B's is consumed.
        _ = m.handle(.message(.click(eventId: "C"), generation: 1))
        _ = m.handle(.message(.click(eventId: "D"), generation: 1))
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [.offerOpened(eventId: "C")])
        XCTAssertEqual(emitted(m.handle(.offerRefused)), [])
        XCTAssertEqual(m.unpairedClicks, [])
    }

    func testOverlappingTapsPairInTapOrderWhenOpensComeFirst() throws {
        // Cached token: open(A), open(B, refused), click(A), click(B), then open(C), click(C).
        var m = showing(250)
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [])
        XCTAssertEqual(emitted(m.handle(.offerRefused)), [])
        XCTAssertEqual(emitted(m.handle(.message(.click(eventId: "A"), generation: 1))), [.offerOpened(eventId: "A")])
        XCTAssertEqual(emitted(m.handle(.message(.click(eventId: "B"), generation: 1))), [])
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [])
        XCTAssertEqual(emitted(m.handle(.message(.click(eventId: "C"), generation: 1))), [.offerOpened(eventId: "C")])
        XCTAssertEqual(m.pendingOpens, [])
    }

    func testASlowTokenFetchKeepsTheClickForItsOpen() throws {
        // The click waits up to 10 s (clickExpiry), not the open's 1 s.
        var m = showing(250)
        let effects = m.handle(.message(.click(eventId: "slow"), generation: 1))
        XCTAssertTrue(effects.contains(.startTimer(.clickExpiry, generation: 1)))
        XCTAssertFalse(effects.contains(.startTimer(.offerPairing, generation: 1)))
        _ = m.handle(.timerFired(.offerPairing, generation: 1))
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [.offerOpened(eventId: "slow")])
    }

    func testAClickNeverCarriesAcrossGenerations() throws {
        var m = showing(250)
        _ = m.handle(.message(.click(eventId: "old"), generation: 1))
        _ = m.handle(.load)
        _ = m.handle(.navigationCommitted(generation: 2))
        XCTAssertEqual(emitted(m.handle(.offerOpened)), [])
        XCTAssertEqual(emitted(m.handle(.timerFired(.offerPairing, generation: 2))), [.offerOpened(eventId: "")])
    }

    func testALateReadyIsStillAnswered() throws {
        var m = committed(initial: 120)
        _ = m.handle(.timerFired(.ready, generation: 1))
        XCTAssertEqual(m.state, .empty(.readyTimeout))
        let effects = m.handle(.message(.ready(height: 0, bridge: 1), generation: 1))
        XCTAssertEqual(m.state, .waiting)
        XCTAssertEqual(m.height, 0)
        XCTAssertTrue(effects.contains(.sendContext))
        XCTAssertTrue(effects.contains(.startTimer(.content, generation: 1)))
    }

    func testReattachingReloadsAFailedOrTimedOutLoad() throws {
        var f = committed(initial: 120)
        _ = f.handle(.loadFailed(generation: 1))
        let effects = f.handle(.attachedToWindow)
        XCTAssertEqual(f.generation, 2)
        XCTAssertEqual(f.height, 0)
        XCTAssertTrue(effects.contains(.loadPage(generation: 2, newWebView: false)))

        var s = showing(250)
        XCTAssertEqual(s.handle(.attachedToWindow), [])
        var n = waiting()
        _ = n.handle(.message(.empty(reason: "no_fill"), generation: 1))
        XCTAssertEqual(n.handle(.attachedToWindow), [])
    }

    func testDismissIsReported() throws {
        var m = showing(250)
        XCTAssertEqual(emitted(m.handle(.message(.dismiss, generation: 1))), [.dismissed])
        XCTAssertEqual(m.state, .showing(250))
    }

    func testDestroyStopsEverything() throws {
        var m = showing(250)
        let effects = m.handle(.destroy)
        XCTAssertTrue(effects.contains(.teardown))
        XCTAssertTrue(effects.contains(.cancelTimer(.offerPairing)))
        XCTAssertEqual(m.state, .destroyed)
        XCTAssertEqual(m.height, 0)
        XCTAssertEqual(m.handle(.message(.resize(height: 10, loading: false), generation: 1)), [])
        XCTAssertEqual(m.handle(.load), [])
        XCTAssertEqual(m.handle(.contextChanged), [])
    }
}
