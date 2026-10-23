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
    /// What the app knows about the parcel and the user. Setting it sends it again, even unchanged:
    /// the widget fetches offers for it, and a failed or timed-out load retries.
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
    /// Set while a configuration change replaces the context: the reload sends it with its ready,
    /// so it must not go to the page being replaced.
    private var applyingConfiguration = false

    /// The SDK's own content world: the page cannot see or replace the bridge (research R20).
    static let contentWorld = WKContentWorld.world(name: "GroovySDK")
    static let timeout: TimeInterval = 10
    static let offerPairingWindow: TimeInterval = 1

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
    @_spi(GroovyInternal) public func evaluateInWidget(_ script: String, completion: ((Result<Any, Error>) -> Void)? = nil) {
        guard let webView, webView.url?.host == hosts.widgetHost else { return }
        webView.evaluateJavaScript(script, in: nil, in: .page) { completion?($0) }
    }

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
    /// reaches `createWebViewWith` (research R6).
    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        controller.add(bridge.messageHandler, contentWorld: Self.contentWorld, name: BridgeScript.handlerName)
        controller.addUserScript(WKUserScript(source: BridgeScript.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.contentWorld))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        // The video designs autoplay muted, as on the web; sound still needs a tap.
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.websiteDataStore = .default()

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
        // The context holds the user ID: never to a page that is not the widget (research R6, R20).
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
            handle(.message(parsed, generation: generation))
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

    fileprivate func decide(_ action: WKNavigationAction, isWindowRequest: Bool) -> NavigationDecision {
        // `sourceFrame` is documented non-null, but read defensively: no source means not the main frame.
        let source: WKFrameInfo? = action.sourceFrame
        let decision = NavigationPolicy.decide(url: action.request.url,
                                               sourceIsMainFrame: source?.isMainFrame ?? false,
                                               // No target frame is a new window, whichever delegate asks.
                                               targetIsMainFrame: isWindowRequest ? nil : action.targetFrame.map { $0.isMainFrame },
                                               userActivated: action.navigationType == .linkActivated,
                                               hosts: hosts)
        switch decision {
        case .openOffer:
            handle(open(action.request.url) ? .offerOpened : .offerRefused)
        case .openLink:
            _ = open(action.request.url)
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

