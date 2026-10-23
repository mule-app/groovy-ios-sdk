import Foundation

/// The view's state machine (data-model "Widget view state"), free of UIKit and WebKit so every
/// transition is unit-tested. The view feeds it inputs and performs the effects it returns, in
/// order. The Android SDK implements the same machine (`WidgetState.kt`).
struct WidgetStateMachine {
    enum State: Equatable {
        case idle
        /// Page loading; no `groovy:ready` answered yet in this generation.
        case loading
        /// `groovy:ready` answered with a context; waiting for content.
        case waiting
        /// Content shown at this height.
        case showing(CGFloat)
        case empty(EmptyCause)
        case destroyed
    }

    /// Why the view is empty, with what decides the next transition (data-model).
    enum EmptyCause: Equatable {
        /// From the widget: no_fill, error, account_rejected.
        case widget(GroovyEmptyReason)
        /// The page failed to load.
        case loadFailed
        /// No `groovy:ready` within 10 s: a late ready, the next context or a re-attach recovers.
        case readyTimeout
        /// Ready, but no content and no `groovy:empty` within 10 s of a context.
        case contentTimeout
        /// The widget speaks another protocol version, or the WebView cannot host the bridge.
        case unsupported
        /// Renderer losses twice in a row.
        case rendererLost

        var reason: GroovyEmptyReason {
            switch self {
            case .widget(let reason): return reason
            case .loadFailed: return .loadFailed
            case .readyTimeout, .contentTimeout: return .timeout
            case .unsupported: return .unsupported
            case .rendererLost: return .error
            }
        }
    }

    enum Input: Equatable {
        /// First load, or a configuration change.
        case load
        /// The view entered a window again: recovers a load that failed or timed out.
        case attachedToWindow
        /// The current generation's navigation committed (`didCommit`); messages count from here.
        case navigationCommitted(generation: Int)
        case message(BridgeMessage, generation: Int)
        /// `groovy:ready` named another protocol version.
        case unsupportedBridge(Int, generation: Int)
        case contextChanged
        case loadFailed(generation: Int)
        case timerFired(Timer, generation: Int)
        /// The navigation rule opened an offer.
        case offerOpened
        /// The navigation rule allowed an offer but it could not open (a sheet is already up): its
        /// click must not pair with a later open.
        case offerRefused
        case rendererLost
        case destroy
    }

    enum Timer: Equatable {
        /// 10 s for the first `groovy:ready`.
        case ready
        /// 10 s for content after a context.
        case content
        /// 1 s for the `groovy:click`s of opens that came before them (research R6).
        case offerPairing
        /// 10 s for an open to use a `groovy:click` that came first (the widget may be fetching a
        /// context token between the two); then the waiting clicks are dropped.
        case clickExpiry
    }

    enum Effect: Equatable {
        /// Lay out at this height (points; 0 shows the 1-pixel clipped frame).
        case setHeight(CGFloat)
        /// Start a new generation's navigation (on a fresh WebView when `newWebView`).
        case loadPage(generation: Int, newWebView: Bool)
        case sendContext
        case startTimer(Timer, generation: Int)
        case cancelTimer(Timer)
        case emit(GroovyWidgetEvent)
        /// Whether VoiceOver may read the WebView (only while content shows).
        case setAccessible(Bool)
        /// A short line for the debug log (never a payload, the context or a URL).
        case log(String)
        /// Tear the WebView down for good.
        case teardown
    }

    static let allTimers: [Timer] = [.ready, .content, .offerPairing, .clickExpiry]

    /// The longest either queue gets: a tap storm cannot grow them without bound.
    static let maxQueued = 8

    private(set) var state: State = .idle
    /// Bumped by every load; inputs of another generation are dropped.
    private(set) var generation = 0
    /// The height `loading` and `waiting` report in this generation.
    private(set) var startHeight: CGFloat = 0
    /// The reserved height; read when a generation starts from `idle` or a configuration change.
    var initialHeight: CGFloat = 0
    /// Whether the current generation's navigation committed.
    private(set) var committed = false
    /// Whether this generation answered a `groovy:ready` (only the first one counts).
    private(set) var answeredReady = false
    /// Whether this generation reported `loaded` (later heights report `resized`).
    private(set) var reportedLoaded = false
    /// Renderer losses in a row: reset when content shows, so only a crash loop collapses the view.
    private(set) var consecutiveRendererLosses = 0
    /// Each tap posts its `groovy:click` then opens its offer, so clicks and opens each arrive in
    /// tap order, and the n-th open belongs to the n-th click. Opens can come before their clicks
    /// (a cached context token) or after (a token fetched first): both queues pair first in, first
    /// out. Clicks that no open has used yet:
    private(set) var unpairedClicks: [String] = []
    /// Opens that came before their clicks: `true` when the offer opened (reported), `false` when
    /// it was refused (its click is consumed silently).
    private(set) var pendingOpens: [Bool] = []
    /// The empty reason last reported, until content shows: the same reason is not reported twice
    /// in a row (a reload after a renderer loss, or a context answered with the same empty).
    private(set) var lastReportedEmpty: GroovyEmptyReason?

    /// The height layout uses now (data-model): `showing(h)` → h; `loading`/`waiting` → start
    /// height; otherwise 0.
    var height: CGFloat {
        switch state {
        case .showing(let h): return h
        case .loading, .waiting: return startHeight
        case .idle, .empty, .destroyed: return 0
        }
    }

    /// Feed one input; returns the effects to perform, in order (see the transitions in
    /// data-model "Widget view state").
    mutating func handle(_ input: Input) -> [Effect] {
        if state == .destroyed { return [] }
        switch input {
        case .load:
            // A new configuration is a new widget: its first empty is reported even if the old one was.
            lastReportedEmpty = nil
            return startGeneration(at: initialHeight, newWebView: false, reason: "load")
        case .attachedToWindow:
            switch state {
            case .empty(.loadFailed), .empty(.readyTimeout):
                return startGeneration(at: 0, newWebView: false, reason: "reload on re-attach")
            case .empty(.rendererLost):
                // One more attempt per app action; a renderer that keeps dying collapses again.
                return startGeneration(at: 0, newWebView: true, reason: "reload on re-attach after renderer losses")
            default:
                return []
            }
        case .navigationCommitted(let g):
            guard g == generation else { return [] }
            committed = true
            return []
        case .message(let message, let g):
            guard g == generation, committed else { return [] }
            return handle(message)
        case .unsupportedBridge(let version, let g):
            guard g == generation, committed else { return [] }
            return enterEmpty(.unsupported, log: "widget speaks bridge \(version), SDK needs \(bridgeVersion)")
        case .contextChanged:
            return contextChanged()
        case .loadFailed(let g):
            guard g == generation, state == .loading else { return [] }
            return enterEmpty(.loadFailed, log: "widget page failed to load")
        case .timerFired(let timer, let g):
            guard g == generation else { return [] }
            return timerFired(timer)
        case .offerOpened, .offerRefused:
            let opened = input == .offerOpened
            if !unpairedClicks.isEmpty {
                let eventId = unpairedClicks.removeFirst()
                var effects: [Effect] = opened ? [.emit(.offerOpened(eventId: eventId))] : []
                if unpairedClicks.isEmpty { effects.insert(.cancelTimer(.clickExpiry), at: 0) }
                return effects
            }
            var effects: [Effect] = []
            if pendingOpens.count >= Self.maxQueued, pendingOpens.removeFirst() {
                effects.append(.emit(.offerOpened(eventId: "")))
            }
            pendingOpens.append(opened)
            return effects + [.startTimer(.offerPairing, generation: generation)]
        case .rendererLost:
            switch state {
            case .idle, .empty(.unsupported): return []
            default: break
            }
            consecutiveRendererLosses += 1
            if consecutiveRendererLosses >= 2 {
                return enterEmpty(.rendererLost, log: "widget renderer lost twice in a row")
            }
            return startGeneration(at: height, newWebView: true, reason: "reload after renderer loss")
        case .destroy:
            state = .destroyed
            return Self.allTimers.map { .cancelTimer($0) } + [.setHeight(0), .teardown]
        }
    }

    // MARK: - Transitions

    private mutating func startGeneration(at height: CGFloat, newWebView: Bool, reason: String) -> [Effect] {
        generation += 1
        startHeight = height
        state = .loading
        committed = false
        answeredReady = false
        reportedLoaded = false
        unpairedClicks = []
        var effects: [Effect] = Self.allTimers.map { .cancelTimer($0) }
        effects += pendingOpens.filter { $0 }.map { _ in .emit(.offerOpened(eventId: "")) }
        pendingOpens = []
        effects += [
            .log("\(reason) (generation \(generation))"),
            .setAccessible(false),
            .setHeight(height),
            .loadPage(generation: generation, newWebView: newWebView),
            .startTimer(.ready, generation: generation),
        ]
        return effects
    }

    private mutating func handle(_ message: BridgeMessage) -> [Effect] {
        switch message {
        case .ready:
            guard !answeredReady else { return [] }
            switch state {
            case .loading:
                answeredReady = true
                state = .waiting
                return [.cancelTimer(.ready), .log("widget ready"), .sendContext, .startTimer(.content, generation: generation)]
            case .empty(.readyTimeout):
                // A ready that came after its timer: answer it, from 0 (the view already collapsed).
                answeredReady = true
                startHeight = 0
                state = .waiting
                return [.log("widget ready after the timeout"), .sendContext, .startTimer(.content, generation: generation)]
            default:
                return []
            }
        case .resize(let h, let loading):
            return content(height: h, loading: loading)
        case .expand(let h), .collapse(let h):
            return content(height: h, loading: false)
        case .empty(let raw):
            let reason: GroovyEmptyReason
            switch raw {
            case "no_fill": reason = .noFill
            case "account_rejected": reason = .accountRejected
            default: reason = .error
            }
            return enterEmpty(.widget(reason), log: "widget empty: \(reason.rawValue)")
        case .dismiss:
            return [.emit(.dismissed)]
        case .click(let eventId):
            if !pendingOpens.isEmpty {
                let opened = pendingOpens.removeFirst()
                var effects: [Effect] = opened ? [.emit(.offerOpened(eventId: eventId))] : []
                if pendingOpens.isEmpty { effects.insert(.cancelTimer(.offerPairing), at: 0) }
                return effects
            }
            if unpairedClicks.count >= Self.maxQueued { unpairedClicks.removeFirst() }
            unpairedClicks.append(eventId)
            return [.startTimer(.clickExpiry, generation: generation)]
        }
    }

    private mutating func content(height h: CGFloat, loading: Bool) -> [Effect] {
        guard !loading, h > 0 else { return [] }
        switch state {
        case .waiting, .loading, .showing, .empty(.widget(.noFill)), .empty(.widget(.error)), .empty(.contentTimeout):
            break
        default:
            return []
        }
        if case .showing(let current) = state, current == h { return [] }
        let first = !reportedLoaded
        reportedLoaded = true
        consecutiveRendererLosses = 0
        lastReportedEmpty = nil
        state = .showing(h)
        return [
            .cancelTimer(.ready),
            .cancelTimer(.content),
            .setHeight(h),
            .setAccessible(true),
            .emit(first ? .loaded(h) : .resized(h)),
        ]
    }

    private mutating func contextChanged() -> [Effect] {
        switch state {
        case .waiting:
            return [.sendContext, .startTimer(.content, generation: generation)]
        case .showing:
            return [.sendContext]
        case .empty(.widget(.noFill)), .empty(.widget(.error)), .empty(.contentTimeout):
            startHeight = 0
            state = .waiting
            return [.setHeight(0), .sendContext, .startTimer(.content, generation: generation)]
        case .empty(.loadFailed), .empty(.readyTimeout):
            return startGeneration(at: 0, newWebView: false, reason: "reload on a new context")
        case .empty(.rendererLost):
            // One more attempt per app action; a renderer that keeps dying collapses again.
            return startGeneration(at: 0, newWebView: true, reason: "reload on a new context after renderer losses")
        case .empty(.widget(.accountRejected)):
            return [.sendContext]
        case .empty(.widget), .empty(.unsupported), .idle, .loading, .destroyed:
            return []
        }
    }

    private mutating func timerFired(_ timer: Timer) -> [Effect] {
        switch timer {
        case .ready:
            guard state == .loading else { return [] }
            return enterEmpty(.readyTimeout, log: "no widget ready within 10 s")
        case .content:
            guard state == .waiting else { return [] }
            return enterEmpty(.contentTimeout, log: "no content within 10 s of the context")
        case .offerPairing:
            // These opens' clicks never came: report the opened ones without an id.
            let effects: [Effect] = pendingOpens.filter { $0 }.map { _ in .emit(.offerOpened(eventId: "")) }
            pendingOpens = []
            return effects
        case .clickExpiry:
            unpairedClicks = []
            return []
        }
    }

    private mutating func enterEmpty(_ cause: EmptyCause, log: String) -> [Effect] {
        state = .empty(cause)
        var effects: [Effect] = [.cancelTimer(.ready), .cancelTimer(.content), .log(log), .setAccessible(false), .setHeight(0)]
        // The same reason again, with no content between (the widget answers each context with
        // `groovy:empty`, or a reload after a renderer loss finds the same): nothing new to report.
        if lastReportedEmpty != cause.reason {
            lastReportedEmpty = cause.reason
            effects.append(.emit(.empty(cause.reason)))
        }
        return effects
    }
}
