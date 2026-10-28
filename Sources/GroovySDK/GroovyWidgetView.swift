import SafariServices
import UIKit
import WebKit

/// The Groovy widget as a UIKit view. Give it the width of its placement; its height follows the
/// widget (`intrinsicContentSize`), starting at `initialHeight` (0 by default).
///
/// It owns a WKWebView that loads the hosted widget at its top level, delivers the context, sizes
/// itself from the widget's messages, opens offers in an in-app browser sheet, and reports what
/// happened to its listener. Behaviour: specs/222-mobile-sdk/data-model.md "Widget view state".
public final class GroovyWidgetView: UIView {
    /// What the app knows about the parcel. Setting it sends it again, even unchanged: the widget
    /// fetches offers for it, and a failed or timed-out load retries.
    public var context: GroovyContext {
        didSet { if !applyingConfiguration { handle(.contextChanged) } }
    }

    /// The reserved height for the publisher's design, in points (0 to 10,000; others are
    /// clamped). Applies from the next load, never to the one on screen.
    public var initialHeight: CGFloat {
        didSet { machine.initialHeight = Self.clampInitialHeight(initialHeight) }
    }

    /// Receives the view's events on the main thread.
    public weak var listener: GroovyWidgetListener?

    /// The SwiftUI adapter's event closure.
    var onEvent: ((GroovyWidgetEvent) -> Void)?

    /// Tests only: serve this HTML for the widget address (on its origin) instead of loading it.
    var testPage: ((URL) -> String)?

    /// Tests only: open offers and links here instead of a sheet; returns whether it opened (as the
    /// Android SDK's `testOpener`). A presented sheet cannot be dismissed deterministically in a test.
    var testOpener: ((URL) -> Bool)?

    private(set) var configuration: WidgetConfiguration
    private var hosts: EnvironmentHosts
    private var machine = WidgetStateMachine()
    private var webView: WKWebView?
    private lazy var bridge = WebViewBridge(owner: self)
    private var timers: [WidgetStateMachine.Timer: Timer] = [:]
    /// The generation each navigation belongs to.
    private var navigations: [ObjectIdentifier: Int] = [:]
    private var layoutHeight: CGFloat = 0
    private var started = false
    /// Spec 230 — the native taps that allow an external page to open (data-model "Tap gate").
    private var tapGate = TapGate()
    /// Feeds the gate from the touches the WebView handles, without taking any of them.
    private lazy var tapObserver = TapObserver { [weak self] at in self?.tapGate.noteTap(at: at) }
    /// Spec 230 plan §17 question 3 (answer A): while a screen reader or switch access runs, the
    /// widget's `groovy:click` counts as the tap. Injectable for the tests.
    var assistiveTechnologyRunning: () -> Bool = {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }
    /// A click URL that arrived with no tap while assistive technology runs: held for the pairing
    /// window, opened when its `groovy:click` arrives (with a cached token the widget opens before
    /// its click message is delivered), refused when the window passes (data-model "Tap gate").
    /// Spec 230 — click URLs refused for want of a tap, each waiting the pairing window for its
    /// `groovy:click` (with a cached token the open arrives before the click): oldest first, at most
    /// `maxHeldOffers`, one timer for the oldest.
    private var heldOffers: [(url: URL, at: TimeInterval)] = []
    private var heldOfferTimer: Timer?
    static let maxHeldOffers = 4
    /// Set while a configuration change replaces the context: the reload sends it with its ready,
    /// so it must not go to the page being replaced.
    private var applyingConfiguration = false

    /// The SDK's own content world: the page cannot see or replace the bridge (research R20).
    static let contentWorld = WKContentWorld.world(name: "GroovySDK")
    /// Spec 230 (data-model "Web storage") — the widget's own web storage: one non-persistent store
    /// for every widget WebView of this process, apart from the app's default store and from any
    /// other, gone when the process ends.
    static let dataStore = WKWebsiteDataStore.nonPersistent()
    static let timeout: TimeInterval = 10
    static let offerPairingWindow: TimeInterval = 1

    /// The monotonic clock the tap gate uses (never the wall clock, which the device can change).
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    public init(publisherId: String, accountId: String, placement: String? = nil,
                widgetVariant: String? = nil, experiment: GroovyExperiment? = nil,
                initialHeight: CGFloat = 0, context: GroovyContext = GroovyContext()) {
        let environment = Settings.shared.environment
        self.configuration = WidgetConfiguration(publisherId: publisherId, accountId: accountId,
                                                 placement: placement, widgetVariant: widgetVariant,
                                                 experiment: experiment, environment: environment)
        self.hosts = EnvironmentHosts.of(environment)
        self.context = context
        self.initialHeight = initialHeight
        super.init(frame: .zero)
        machine.initialHeight = Self.clampInitialHeight(initialHeight)
        clipsToBounds = true
        backgroundColor = .clear
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        addGestureRecognizer(tapObserver)
    }

    @available(*, unavailable, message: "GroovyWidgetView needs a publisher ID and an account ID: use init(publisherId:accountId:…)")
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        timers.values.forEach { $0.invalidate() }
        // A view can be released off the main thread; WebKit must be torn down on it.
        if let webView {
            let bridge = self.bridge
            if Thread.isMainThread {
                Self.tearDown(webView, bridge: bridge)
            } else {
                DispatchQueue.main.async { Self.tearDown(webView, bridge: bridge) }
            }
        }
    }

    // MARK: - Layout

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: layoutHeight)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        if !started {
            started = true
            handle(.load)
        } else {
            handle(.attachedToWindow)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard let webView else { return }
        // At height 0 the WebView keeps a 1-pixel frame, clipped by this view, so the page's
        // animation frames and observers keep running (research R16).
        let height = max(bounds.height, 1)
        webView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
    }

    /// The height in points, rounded up to the device pixel as the widget's heights are.
    private func setLayoutHeight(_ height: CGFloat) {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let rounded = (height * scale).rounded(.up) / scale
        guard rounded != layoutHeight else { return }
        layoutHeight = rounded
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        setNeedsLayout()
    }

    // MARK: - Configuration (the SwiftUI adapter)

    /// Apply a new configuration, initial height and context in one step: the initial height first,
    /// then at most one new generation, then the context (data-model "Widget view state").
    func update(configuration newConfiguration: WidgetConfiguration, initialHeight newInitialHeight: CGFloat,
                context newContext: GroovyContext) {
        if newInitialHeight != initialHeight { initialHeight = newInitialHeight }
        if newConfiguration != configuration {
            configuration = newConfiguration
            hosts = EnvironmentHosts.of(newConfiguration.environment)
            // The new load sends the latest context with its ready; the old page never gets it.
            applyingConfiguration = true
            context = newContext
            applyingConfiguration = false
            if started { handle(.load) }
            return
        }
        if newContext != context { context = newContext }
    }

    /// Internal, for the sample app's scripted runs only (not in the guide): run JavaScript in the
    /// widget page, as the page's own code, for instance to tap a button the way a visitor would.
    /// Since 1.0.1 a tap from script opens nothing: see `simulateTap()`.
    @_spi(GroovyInternal) public func evaluateInWidget(_ script: String, completion: ((Result<Any, Error>) -> Void)? = nil) {
        guard let webView, webView.url?.host == hosts.widgetHost else { return }
        webView.evaluateJavaScript(script, in: nil, in: .page) { completion?($0) }
    }

    #if DEBUG
    /// Debug builds only, for the sample app's scripted runs and the tests (not in the guide): record
    /// a native tap, as a touch ending inside the view would (data-model "Tap gate"). Absent from
    /// release builds, so no app can bypass the gate through the SPI.
    @_spi(GroovyInternal) public func simulateTap() {
        tapGate.noteTap(at: Self.now())
    }
    #endif

    /// Tear down now (SwiftUI's `dismantleUIView`): every later message and timer is dropped.
    func destroy() {
        handle(.destroy)
    }

    // MARK: - State machine

    private func handle(_ input: WidgetStateMachine.Input) {
        perform(machine.handle(input))
    }

    private func perform(_ effects: [WidgetStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .setHeight(let height):
                setLayoutHeight(height)
            case .loadPage(let generation, let newWebView):
                loadPage(generation: generation, newWebView: newWebView)
            case .sendContext:
                sendContext()
            case .startTimer(let timer, let generation):
                startTimer(timer, generation: generation)
            case .cancelTimer(let timer):
                timers.removeValue(forKey: timer)?.invalidate()
            case .emit(let event):
                emit(event)
            case .setAccessible(let accessible):
                webView?.accessibilityElementsHidden = !accessible
            case .log(let line):
                Log.debug(line)
            case .teardown:
                dropHeldOffers()
                if let webView { Self.tearDown(webView, bridge: bridge) }
                webView = nil
                navigations.removeAll()
            }
        }
    }

    private func startTimer(_ timer: WidgetStateMachine.Timer, generation: Int) {
        timers[timer]?.invalidate()
        let interval = timer == .offerPairing ? Self.offerPairingWindow : Self.timeout
        timers[timer] = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timers.removeValue(forKey: timer)
            self.handle(.timerFired(timer, generation: generation))
        }
    }

    private func emit(_ event: GroovyWidgetEvent) {
        switch event {
        case .loaded(let height): Log.info("widget loaded at \(Int(height)) pt")
        case .empty(let reason): Log.info("widget empty: \(reason.rawValue)")
        default: break
        }
        onEvent?(event)
        guard let listener else { return }
        switch event {
        case .loaded(let height): listener.groovyWidget(self, didLoadWithHeight: height)
        case .resized(let height): listener.groovyWidget(self, didResizeTo: height)
        case .offerOpened(let eventId): listener.groovyWidget(self, didOpenOfferWithEventId: eventId)
        case .dismissed: listener.groovyWidgetDidDismiss(self)
        case .empty(let reason): listener.groovyWidget(self, isEmpty: reason)
        }
    }

    // MARK: - WebView

    /// A WKWebView with the bridge in the SDK's content world, transparent, not scrollable, with
    /// `javaScriptCanOpenWindowsAutomatically` so the widget's `window.open` after an `await`
    /// reaches `createWebViewWith` (research R6), where the tap gate decides (spec 230 R1: the SDK
    /// must see every open to refuse it); on the SDK's own data store, with the lockdown script in
    /// the page's world in every frame (spec 230 R4, R5).
    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        controller.add(bridge.messageHandler, contentWorld: Self.contentWorld, name: BridgeScript.handlerName)
        controller.addUserScript(WKUserScript(source: BridgeScript.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.contentWorld))
        // Spec 230 — no geolocation or media capture for the page or any frame it creates, before
        // any page script runs (the page's world: each world has its own `navigator` wrapper).
        controller.addUserScript(WKUserScript(source: LockdownScript.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        // The video designs autoplay muted, as on the web; sound still needs a tap.
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.websiteDataStore = Self.dataStore

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, 1)),
                             configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.accessibilityElementsHidden = true
        view.navigationDelegate = bridge
        view.uiDelegate = bridge
        return view
    }

    private func loadPage(generation: Int, newWebView: Bool) {
        // Spec 230 — a tap authorises an open on the page it was made on, never on the next one
        // (another placement or publisher), and a held open belongs to the page that asked for it.
        tapGate = TapGate()
        dropHeldOffers()
        if newWebView, let old = webView {
            Self.tearDown(old, bridge: bridge)
            webView = nil
            navigations.removeAll()
        }
        let view = webView ?? {
            let created = makeWebView()
            addSubview(created)
            webView = created
            return created
        }()
        guard let url = WidgetURL.build(configuration) else {
            Log.info("publisher ID cannot form the widget address: nothing loaded")
            handle(.loadFailed(generation: generation))
            return
        }
        if configuration.environment != .production {
            Log.warning("loading the widget from the \(configuration.environment.rawValue) environment, not production")
        }
        Log.debug("loading \(url.host ?? "")\(url.path)")
        let navigation = testPage.map { view.loadHTMLString($0(url), baseURL: url) } ?? view.load(URLRequest(url: url))
        if let navigation {
            navigations[ObjectIdentifier(navigation)] = generation
        }
        setNeedsLayout()
    }

    private func sendContext() {
        guard let webView else { return }
        // The app's context: never to a page that is not the widget (research R6, R20).
        guard webView.url?.scheme == "https", webView.url?.host == hosts.widgetHost else {
            Log.debug("context not sent: the page is not the widget")
            return
        }
        let script = BridgeScript.deliverContext(ContextEncoder.json(context), widgetHost: hosts.widgetHost)
        webView.evaluateJavaScript(script, in: nil, in: Self.contentWorld) { result in
            if case .failure = result { Log.debug("context delivery failed") }
        }
        Log.debug("context sent")
    }

    private static func tearDown(_ webView: WKWebView, bridge: WebViewBridge) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: BridgeScript.handlerName, contentWorld: contentWorld)
        controller.removeAllUserScripts()
        webView.removeFromSuperview()
    }

    // MARK: - Bridge callbacks (WebViewBridge)

    fileprivate func received(_ message: WKScriptMessage) {
        guard let webView, message.webView === webView, message.frameInfo.isMainFrame else {
            Log.debug("message from a sub-frame dropped")
            return
        }
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == "https", origin.host == hosts.widgetHost, origin.port == 0 || origin.port == 443 else {
            Log.debug("message from another origin dropped")
            return
        }
        guard let body = message.body as? String else { return }
        let generation = machine.generation
        switch BridgeMessageParser.parse(body) {
        case .message(let parsed):
            Log.debug(Self.describe(parsed))
            // A click that belongs to a held open (spec 230): without assistive technology the hold
            // is the refusal this click consumes, fed first so it is the one consumed; with it, the
            // held URL opens once the machine queued the click, so they pair.
            var heldForClick = false
            if case .click = parsed, !heldOffers.isEmpty { heldForClick = true }
            let assistive = assistiveTechnologyRunning()
            if heldForClick && !assistive { releaseHeldOffer(open: false) }
            noteForTapGate(parsed, heldForClick: heldForClick)
            handle(.message(parsed, generation: generation))
            if heldForClick && assistive { releaseHeldOffer(open: true) }
        case .unsupportedBridge(let version):
            handle(.unsupportedBridge(version, generation: generation))
        case .dropped(let reason):
            Log.debug("message dropped: \(reason)")
        }
    }

    fileprivate func committed(_ navigation: WKNavigation?, in webView: WKWebView) {
        guard webView === self.webView, let navigation, let generation = navigations[ObjectIdentifier(navigation)] else { return }
        handle(.navigationCommitted(generation: generation))
    }

    fileprivate func failed(_ navigation: WKNavigation?, in webView: WKWebView, error: Error) {
        guard webView === self.webView, let navigation, let generation = navigations[ObjectIdentifier(navigation)] else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        handle(.loadFailed(generation: generation))
    }

    fileprivate func processTerminated(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        Log.info("widget renderer terminated")
        handle(.rendererLost)
    }

    /// Spec 230 — what a bridge message says about the last tap: a `groovy:dismiss` means the tap
    /// declined an offer and opens nothing; under a screen reader or switch access, a
    /// `groovy:click` counts as the tap: for the open that follows it (a token being fetched), or
    /// for the one held just before it (a cached token). Returns whether a held open is released.
    /// What a message means to the gate: a dismiss consumed the tap that declined; under assistive
    /// technology a click is an activation, unless it belongs to a held open (then it is that open's).
    private func noteForTapGate(_ message: BridgeMessage, heldForClick: Bool) {
        switch message {
        case .dismiss:
            tapGate.consumeForMessage(at: Self.now())
        case .click:
            if !heldForClick && assistiveTechnologyRunning() { tapGate.noteActivation(at: Self.now()) }
        default:
            break
        }
    }

    /// The click URL with no tap (data-model "Tap gate"): nothing opens, and the refusal consumes
    /// the click the widget posted for this open, so the next real tap pairs with its own click.
    /// When the machine already holds an unpaired click, the refusal is its own and is fed at once.
    /// Otherwise the click may still be on its way (a cached token): the refusal is held for the
    /// pairing window and fed when the click arrives, or opened instead under assistive technology.
    /// A hold whose click never comes is dropped, never fed, so an open the page made with no click
    /// (a script on the click URL) can never take a later genuine tap's click. Never the URL in the log.
    private func refuseOffer(_ url: URL?) {
        guard let url, machine.unpairedClicks.isEmpty else {
            Log.debug("open refused: no tap")
            handle(.offerRefused)
            return
        }
        if heldOffers.count >= Self.maxHeldOffers { heldOffers.removeFirst() }
        heldOffers.append((url, Self.now()))
        Log.debug(assistiveTechnologyRunning() ? "open held for its click (assistive technology)" : "open refused: no tap")
        scheduleHeldOfferExpiry()
    }

    /// One timer, for the oldest hold.
    private func scheduleHeldOfferExpiry() {
        heldOfferTimer?.invalidate()
        heldOfferTimer = nil
        guard let oldest = heldOffers.first else { return }
        let delay = max(0, Self.offerPairingWindow - (Self.now() - oldest.at))
        heldOfferTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.expireHeldOffers()
        }
    }

    /// The window passed: the holds whose click never came are dropped, nothing fed.
    private func expireHeldOffers() {
        let now = Self.now()
        let before = heldOffers.count
        heldOffers.removeAll { now - $0.at >= Self.offerPairingWindow }
        if heldOffers.count < before { Log.debug("held open dropped: its click never came") }
        scheduleHeldOfferExpiry()
    }

    /// A `groovy:click` arrived for the oldest held open: open it (assistive technology) or feed the
    /// refusal it is (the click then pairs with it, or with an older genuine open first in the queue).
    private func releaseHeldOffer(open shouldOpen: Bool) {
        guard !heldOffers.isEmpty else { return }
        let held = heldOffers.removeFirst()
        scheduleHeldOfferExpiry()
        if shouldOpen {
            handle(open(held.url) ? .offerOpened : .offerRefused)
        } else {
            handle(.offerRefused)
        }
    }

    /// A new page, or teardown: the holds were the old page's.
    private func dropHeldOffers() {
        heldOfferTimer?.invalidate()
        heldOfferTimer = nil
        heldOffers.removeAll()
    }

    fileprivate func decide(_ action: WKNavigationAction, isWindowRequest: Bool) -> NavigationDecision {
        // `sourceFrame` is documented non-null, but read defensively: no source means not the main frame.
        let source: WKFrameInfo? = action.sourceFrame
        let decision = NavigationPolicy.decide(url: action.request.url,
                                               sourceIsMainFrame: source?.isMainFrame ?? false,
                                               // No target frame is a new window, whichever delegate asks.
                                               targetIsMainFrame: isWindowRequest ? nil : action.targetFrame.map { $0.isMainFrame },
                                               // Spec 230 — asked only when the page would open; consumes the tap.
                                               tapped: { tapGate.consume(at: Self.now()) },
                                               hosts: hosts,
                                               // Spec 230 (PR 976) — the main frame stays only on the widget
                                               // document this configuration loads.
                                               marker: WidgetURL.marker(for: configuration))
        switch decision {
        case .openOffer:
            handle(open(action.request.url) ? .offerOpened : .offerRefused)
        case .refuseOffer:
            // Spec 230 — no tap: nothing opens; the click the widget posted for this open is the
            // refusal's to consume (see `refuseOffer`).
            refuseOffer(action.request.url)
        case .openLink:
            _ = open(action.request.url)
        case .refuseLink:
            Log.debug("open refused: no tap")
        case .allow, .cancel:
            break
        }
        return decision
    }

    // MARK: - Offers

    /// Open in `SFSafariViewController` from the nearest view controller; with none, in the system
    /// browser; with neither, a debug line. Returns whether a sheet or the browser opened. Never
    /// logs the URL.
    private func open(_ url: URL?) -> Bool {
        guard let url else { return false }
        if let testOpener { return testOpener(url) }
        if let presenter = nearestViewController() {
            guard presenter.presentedViewController == nil else {
                Log.debug("an offer is already open: this tap is ignored")
                return false
            }
            let safari = SFSafariViewController(url: url)
            safari.modalPresentationStyle = .pageSheet
            presenter.present(safari, animated: true)
            return true
        }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return true
        }
        Log.debug("no view controller or browser to open the offer")
        return false
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                var top = controller
                while let presented = top.presentedViewController, !(presented is SFSafariViewController) {
                    top = presented
                }
                return top
            }
            responder = current.next
        }
        return window?.rootViewController
    }

    private static func describe(_ message: BridgeMessage) -> String {
        switch message {
        case .ready(let height, _): return "← ready (\(Int(height)) pt)"
        case .resize(let height, let loading): return "← resize \(Int(height)) pt\(loading ? " (loading)" : "")"
        case .expand(let height): return "← expand \(Int(height)) pt"
        case .collapse(let height): return "← collapse \(Int(height)) pt"
        case .click: return "← click"
        case .empty(let reason): return "← empty (\(reason.prefix(32)))"
        case .dismiss: return "← dismiss"
        }
    }

    private static func clampInitialHeight(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, 0), BridgeMessageParser.maxHeight)
        if clamped != value { Log.debug("initial height clamped to \(Int(clamped)) pt") }
        return clamped
    }
}

/// WebKit's delegates and the script message handler, kept off `GroovyWidgetView`'s public surface.
/// Holds the view weakly: WebKit retains the message handler strongly (research R17).
final class WebViewBridge: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var owner: GroovyWidgetView?
    // Held here; WebKit holds only the weak proxy in front of it.
    private lazy var receiver = MessageReceiver(bridge: self)
    private(set) lazy var messageHandler = WeakMessageHandler(receiver)

    init(owner: GroovyWidgetView) {
        self.owner = owner
    }

    fileprivate func received(_ message: WKScriptMessage) {
        owner?.received(message)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let owner else { return decisionHandler(.cancel) }
        decisionHandler(owner.decide(navigationAction, isWindowRequest: false) == .allow ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        owner?.committed(navigation, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner?.failed(navigation, in: webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner?.failed(navigation, in: webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.processTerminated(webView)
    }

    /// `window.open` from the widget: never a child WebView (it would load `/trk/c` a second time).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        _ = owner?.decide(navigationAction, isWindowRequest: true)
        return nil
    }

    /// Spec 230 (FR-009) — the widget never needs the camera or the microphone: refused, with no
    /// prompt (WebKit prompts when this is not implemented).
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        Log.debug("media capture refused")
        decisionHandler(.deny)
    }

    /// Spec 230 (FR-009, in spirit) — nor device motion and orientation: refused, no prompt.
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        Log.debug("device motion refused")
        decisionHandler(.deny)
    }

    /// Spec 230 (FR-009, in spirit) — a file chooser the page could open (which can offer the
    /// camera) never shows: on iOS 18.4 and later, where WebKit asks, it is cancelled. The type
    /// exists on iOS only from the iOS 18.4 SDK (Xcode 16.3, Swift 6.1); an older toolchain builds
    /// the SDK without this method, and the lockdown script and `Permissions-Policy` remain.
    #if compiler(>=6.1)
    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        Log.debug("file chooser refused")
        completionHandler(nil)
    }
    #endif

    /// Spec 230 (FR-009) — nor location: refused on iOS 27 and later, where WebKit asks; on iOS 15
    /// to 26 the lockdown script is the guard. Declared with its Objective-C selector so an app
    /// built with an older Xcode still exposes it to WebKit on an iOS 27 device.
    @available(iOS 27.0, *)
    @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        Log.debug("location refused")
        decisionHandler(.deny)
    }
}

/// The `WKScriptMessageHandler` the weak proxy forwards to.
private final class MessageReceiver: NSObject, WKScriptMessageHandler {
    weak var bridge: WebViewBridge?

    init(bridge: WebViewBridge) {
        self.bridge = bridge
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        bridge?.received(message)
    }
}

/// Receives the view's events on the main thread. Every method is optional.
public protocol GroovyWidgetListener: AnyObject {
    func groovyWidget(_ view: GroovyWidgetView, didLoadWithHeight height: CGFloat)
    func groovyWidget(_ view: GroovyWidgetView, didResizeTo height: CGFloat)
    func groovyWidget(_ view: GroovyWidgetView, didOpenOfferWithEventId eventId: String)
    func groovyWidgetDidDismiss(_ view: GroovyWidgetView)
    func groovyWidget(_ view: GroovyWidgetView, isEmpty reason: GroovyEmptyReason)
}

public extension GroovyWidgetListener {
    func groovyWidget(_ view: GroovyWidgetView, didLoadWithHeight height: CGFloat) {}
    func groovyWidget(_ view: GroovyWidgetView, didResizeTo height: CGFloat) {}
    func groovyWidget(_ view: GroovyWidgetView, didOpenOfferWithEventId eventId: String) {}
    func groovyWidgetDidDismiss(_ view: GroovyWidgetView) {}
    func groovyWidget(_ view: GroovyWidgetView, isEmpty reason: GroovyEmptyReason) {}
}

