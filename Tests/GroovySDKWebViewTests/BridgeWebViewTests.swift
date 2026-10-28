import SafariServices
import WebKit
import XCTest
@_spi(GroovyInternal) @testable import GroovySDK

/// T032: the view with the real WKWebView on the simulator. The page is a scripted stand-in for
/// the widget, served on the dev widget origin (`loadHTMLString` with that base URL: a `file://`
/// page would have origin `null`), speaking bridge v1 as `postmessage.js` does at the top level.
/// The real widget is driven end to end from the sample app (quickstart cases).
@MainActor
final class BridgeWebViewTests: XCTestCase {
    private var window: UIWindow!
    private var listener: RecordingListener!

    /// The stand-in widget: ready on load; on a context, a loading height then the content height.
    private static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body style="margin:0"><div id="app" style="height:250px"></div><script>
      window.__contexts = [];
      function post(type, payload) { window.postMessage({ type: type, payload: payload, bridge: 1 }, location.origin); }
      window.addEventListener("message", function (e) {
        if (e.source !== window || e.origin !== location.origin) { return; }
        var d = e.data;
        if (d && d.type === "groovy:context") {
          window.__contexts.push(d.payload);
          post("groovy:resize", { height: 400, loading: true });
          setTimeout(function () { post("groovy:resize", { height: 250 }); }, 50);
        }
      });
      post("groovy:ready", { version: "1.0.0", height: 120, bridge: 1 });
      window.__probe = function (w) {
        try { return [typeof w.navigator.geolocation, typeof w.navigator.mediaDevices, typeof w.navigator.getUserMedia].join(","); }
        catch (e) { return "error:" + e; }
      };
    </script></body></html>
    """

    private static let clickURL = "https://api-dev.joingroovy.com/trk/c?dest=https%3A%2F%2Fadvertiser.example"


    override func setUp() async throws {
        Groovy.environment = .dev
        Groovy.logLevel = .debug
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        listener = RecordingListener()
    }

    override func tearDown() async throws {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window = nil
        Groovy.environment = .production
    }

    /// The offers and links the spec 230 cases opened (through `testOpener`, never a sheet).
    private var opened: [URL] = []

    private func makeView(page: String = page, context: GroovyContext = GroovyContext(retailer: "asos", custom: ["user_id": .string("u-1")]),
                          recordOpens: Bool = false) -> GroovyWidgetView {
        let view = GroovyWidgetView(publisherId: "example-publisher", accountId: "GR-EXAMPLE", initialHeight: 120, context: context)
        view.testPage = { _ in page }
        if recordOpens { view.testOpener = { [weak self] url in self?.opened.append(url); return true } }
        view.listener = listener
        view.translatesAutoresizingMaskIntoConstraints = false
        let root = window.rootViewController!.view!
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: 100),
        ])
        return view
    }

    // 60 s: the suite's first WebView on a cold CI simulator took about 45 s to load (Mobile SDK run
    // 39575485312). A condition that holds returns at once, so passing runs are not slower.
    private func eventually(_ timeout: TimeInterval = 60, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func webView(of view: GroovyWidgetView) -> WKWebView? {
        view.subviews.compactMap { $0 as? WKWebView }.first
    }

    private func run(_ script: String, in view: GroovyWidgetView) async throws -> Any? {
        try await webView(of: view)?.evaluateJavaScript(script)
    }

    func testReadyContextResizeFlow() async throws {
        let view = makeView()
        XCTAssertEqual(view.intrinsicContentSize.height, 120, "starts at the initial height")
        await eventually { listener.events.contains(.loaded(250)) }
        XCTAssertEqual(listener.events.first, .loaded(250), "the loading height (400) is never reported")
        XCTAssertEqual(view.intrinsicContentSize.height, 250)
        // Spec 230: a custom key spelled as a user ID never reaches the page.
        let contexts = try await run("JSON.stringify(window.__contexts)", in: view) as? String
        XCTAssertEqual(contexts, #"[{"retailer":"asos"}]"#)

        // A new context is sent again (FR-009).
        view.context = GroovyContext(retailer: "boots")
        for _ in 0..<100 where (try? await run("window.__contexts.length", in: view) as? Int) != 2 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let count = try await run("window.__contexts.length", in: view) as? Int
        XCTAssertEqual(count, 2)
    }

    func testSettingTheSameContextSendsItAgain() async throws {
        // The contract: setting the context resends it, even unchanged (a retry, a refresh).
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        let same = view.context
        view.context = same
        for _ in 0..<100 where (try? await run("window.__contexts.length", in: view) as? Int) != 2 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let count = try await run("window.__contexts.length", in: view) as? Int
        XCTAssertEqual(count, 2)
    }

    func testASubFramesBlankLinkOpensNothing() async throws {
        // A link with target=_blank inside a sub-frame is a new-window request: refused, whichever
        // WebKit delegate it reaches (NavigationPolicy refuses a sub-frame's window).
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        _ = try await run("""
        var f = document.createElement('iframe');
        f.srcdoc = '<a id="l" href="https://advertiser.example/" target="_blank">x</a>';
        f.onload = function () { f.contentDocument.getElementById('l').click(); };
        document.body.appendChild(f); true
        """, in: view)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(window.rootViewController?.presentedViewController, "a sub-frame's window never opens")
        XCTAssertEqual(webView(of: view)?.url?.host, "widget-embed-dev.joingroovy.com")
    }

    func testContextReachesThePageFromTheSDKContentWorld() async throws {
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        // The page saw it as its own window's message, on its own origin: the widget's rule.
        let page = try await run("window.__contexts[0].retailer", in: view) as? String
        XCTAssertEqual(page, "asos")
        // And the page cannot reach the SDK's bridge.
        let sees = try await run("!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.groovy)", in: view) as? Bool
        XCTAssertEqual(sees, false)
    }

    func testEmptyAndDismissReachTheListener() async throws {
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        _ = try await run("post('groovy:dismiss', {}); true", in: view)
        await eventually { listener.events.contains(.dismissed) }
        _ = try await run("post('groovy:empty', { reason: 'no_fill' }); true", in: view)
        await eventually { listener.events.contains(.empty(.noFill)) }
        XCTAssertEqual(listener.events, [.loaded(250), .dismissed, .empty(.noFill)])
        XCTAssertEqual(view.intrinsicContentSize.height, 0)
    }

    func testOfferOpensWithoutAChildWebView() async throws {
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        // Spec 230: the open needs a native tap; the test records one as a touch would.
        view.simulateTap()
        // As `clickRedirect` does with a cached token: the click message, then `window.open` in the
        // same task, so the open reaches the SDK before the click does.
        _ = try await run("""
        post('groovy:click', { eventId: 'e-9', pageRef: 'p' });
        window.open('https://api-dev.joingroovy.com/trk/c?dest=https%3A%2F%2Fadvertiser.example', '_blank', 'noopener,noreferrer');
        true
        """, in: view)
        await eventually { listener.events.contains(.offerOpened(eventId: "e-9")) }
        XCTAssertEqual(listener.events.last, .offerOpened(eventId: "e-9"))
        XCTAssertTrue(window.rootViewController?.presentedViewController is SFSafariViewController)
        // The widget page is still the one loaded: no navigation, no child WebView.
        XCTAssertEqual(webView(of: view)?.url?.host, "widget-embed-dev.joingroovy.com")
        XCTAssertEqual(view.subviews.compactMap { $0 as? WKWebView }.count, 1)
    }

    func testCrossOriginSubFrameMessageIsDropped() async throws {
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        _ = try await run("""
        var f = document.createElement('iframe');
        f.src = 'data:text/html,<script>parent.postMessage({type:"groovy:resize",payload:{height:999},bridge:1},"*");parent.postMessage({type:"groovy:empty",payload:{reason:"no_fill"},bridge:1},"*")<\\/script>';
        document.body.appendChild(f); true
        """, in: view)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(listener.events, [.loaded(250)])
        XCTAssertEqual(view.intrinsicContentSize.height, 250)
    }

    func testANavigationAwayFromTheWidgetIsRefused() async throws {
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        _ = try await run("location.href = 'https://phish.example/'; true", in: view)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(webView(of: view)?.url?.host, "widget-embed-dev.joingroovy.com")
        XCTAssertNil(window.rootViewController?.presentedViewController, "no tap: nothing opens")
    }

    func testASameHostNavigationWithoutTheMarkerIsRefused() async throws {
        // Spec 230 T043 (the CTO's decision on PR 976): the main frame stays only on the widget
        // document the SDK loaded, so a navigation that drops `sdk_platform`, or names another
        // account, cannot load the hosted page in web mode inside the app.
        let view = makeView(recordOpens: true)
        await eventually { listener.events.contains(.loaded(250)) }
        let before = try XCTUnwrap(webView(of: view)?.url?.absoluteString)
        XCTAssertTrue(before.contains("sdk_platform=ios") && before.contains("account_id=GR-EXAMPLE"), before)
        _ = try await run("var u = new URL(location.href); u.searchParams.delete('sdk_platform'); location.href = u.toString(); true", in: view)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        _ = try await run("var v = new URL(location.href); v.searchParams.set('account_id', 'GR-OTHER'); location.href = v.toString(); true", in: view)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        _ = try await run("var w = new URL(location.href); w.pathname = '/v1/other-publisher/frame.html'; location.href = w.toString(); true", in: view)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(webView(of: view)?.url?.absoluteString, before, "the address still carries the marker")
        XCTAssertEqual(opened, [], "no tap: nothing opens either")
        XCTAssertEqual(listener.events, [.loaded(250)])
        // The page itself is untouched: its own script state survives.
        let postType = try await run("typeof post", in: view) as? String
        XCTAssertEqual(postType, "function")
    }

    func testAConfigurationChangeSendsTheNewContextOnlyToTheNewPage() async throws {
        // Each page load records the contexts it receives under its own id; sessionStorage outlives
        // the reload, so the test can read what the replaced page got.
        let page = Self.page.replacingOccurrences(of: "window.__contexts.push(d.payload);", with: """
        window.__contexts.push(d.payload);
        var log = JSON.parse(sessionStorage.getItem("log") || "[]");
        log.push(window.__pageId + ":" + d.payload.retailer);
        sessionStorage.setItem("log", JSON.stringify(log));
        """).replacingOccurrences(of: "window.__contexts = [];", with: "window.__contexts = []; window.__pageId = String(Math.random()).slice(2, 8);")
        let view = makeView(page: page)
        await eventually { listener.events.contains(.loaded(250)) }
        let first = try await run("window.__pageId", in: view) as? String

        var changed = view.configuration
        changed.placement = "tracking.bottom"
        view.update(configuration: changed, initialHeight: 120, context: GroovyContext(retailer: "boots"))
        await eventually { listener.events.filter { $0 == .loaded(250) }.count == 2 }
        let second = try await run("window.__pageId", in: view) as? String
        XCTAssertNotEqual(first, second)
        let log = try await run("sessionStorage.getItem('log')", in: view) as? String
        XCTAssertEqual(log, "[\"\(first ?? ""):asos\",\"\(second ?? ""):boots\"]")
    }

    // MARK: - Spec 230 T020: tap-only opening, the SDK's own storage, refused permissions

    func testAScriptedOpenWithNoTapOpensNothingAndConsumesItsClick() async throws {
        let view = makeView(recordOpens: true)
        await eventually { listener.events.contains(.loaded(250)) }
        // The widget's click flow from script, with no touch: refused.
        _ = try await run("post('groovy:click', { eventId: 'e-no-tap', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank'); true", in: view)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(opened, [], "no tap: nothing opens")
        XCTAssertFalse(listener.events.contains { if case .offerOpened = $0 { return true } else { return false } })
        // The refused click is consumed: a real tap's open then reports its own event id.
        view.simulateTap()
        _ = try await run("post('groovy:click', { eventId: 'e-real', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank'); true", in: view)
        await eventually { listener.events.contains(.offerOpened(eventId: "e-real")) }
        XCTAssertEqual(listener.events.last, .offerOpened(eventId: "e-real"))
        XCTAssertEqual(opened.map(\.host), ["api-dev.joingroovy.com"])
    }

    func testATapDoesNotCarryOverIntoTheNextPage() async throws {
        let view = makeView(recordOpens: true)
        await eventually { listener.events.contains(.loaded(250)) }
        view.simulateTap()
        var changed = view.configuration
        changed.placement = "tracking.bottom"
        view.update(configuration: changed, initialHeight: 120, context: GroovyContext(retailer: "boots"))
        await eventually { listener.events.filter { $0 == .loaded(250) }.count == 2 }
        _ = try await run("post('groovy:click', { eventId: 'e-next-page', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank'); true", in: view)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(opened, [], "the tap belonged to the replaced page")
        XCTAssertFalse(listener.events.contains { if case .offerOpened = $0 { return true } else { return false } })
    }

    func testTimersRedirectsAndMetaRefreshWithNoTapOpenNothing() async throws {
        let view = makeView(recordOpens: true)
        await eventually { listener.events.contains(.loaded(250)) }
        _ = try await run("""
        setTimeout(function () { window.open('\(Self.clickURL)', '_blank'); }, 100);
        setTimeout(function () { window.open('https://advertiser.example/', '_blank'); }, 200);
        setTimeout(function () { location.href = 'https://phish.example/'; }, 300);
        setTimeout(function () {
          var m = document.createElement('meta'); m.httpEquiv = 'refresh'; m.content = '0;url=https://advertiser.example/';
          document.head.appendChild(m);
        }, 400);
        setTimeout(function () { var a = document.createElement('a'); a.href = 'https://advertiser.example/'; a.target = '_blank'; document.body.appendChild(a); a.click(); }, 500);
        true
        """, in: view)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(webView(of: view)?.url?.host, "widget-embed-dev.joingroovy.com")
        XCTAssertEqual(listener.events, [.loaded(250)])
    }

    func testOneTapOpensOnceAndTwoTapsOpenTwice() async throws {
        let view = makeView(recordOpens: true)
        await eventually { listener.events.contains(.loaded(250)) }
        view.simulateTap()
        _ = try await run("""
        post('groovy:click', { eventId: 'e-1', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank');
        setTimeout(function () { post('groovy:click', { eventId: 'e-2', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank'); }, 300);
        true
        """, in: view)
        await eventually { listener.events.contains(.offerOpened(eventId: "e-1")) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        // One tap: the second open (a timer right after) is refused and its click consumed.
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(listener.events.filter { if case .offerOpened = $0 { return true } else { return false } }.count, 1)

        // Two taps on two offers: two opens, in order; a third open has no tap left.
        view.simulateTap()
        view.simulateTap()
        _ = try await run("""
        post('groovy:click', { eventId: 'e-3', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank');
        setTimeout(function () { post('groovy:click', { eventId: 'e-4', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank'); }, 300);
        setTimeout(function () { post('groovy:click', { eventId: 'e-5', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank'); }, 600);
        true
        """, in: view)
        await eventually { listener.events.contains(.offerOpened(eventId: "e-4")) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(opened.count, 3)
        XCTAssertEqual(Array(listener.events.suffix(2)), [.offerOpened(eventId: "e-3"), .offerOpened(eventId: "e-4")])
    }

    func testUnderAssistiveTechnologyTheClickAuthorisesTheOpenAroundIt() async throws {
        let view = makeView(recordOpens: true)
        view.assistiveTechnologyRunning = { true }
        await eventually { listener.events.contains(.loaded(250)) }
        // A cached token: the open reaches the SDK before the click message is delivered.
        _ = try await run("window.open('\(Self.clickURL)', '_blank'); setTimeout(function () { post('groovy:click', { eventId: 'e-at-1', pageRef: 'p' }); }, 200); true", in: view)
        await eventually { listener.events.contains(.offerOpened(eventId: "e-at-1")) }
        XCTAssertEqual(opened.count, 1)
        // A token being fetched: the click first, then the open.
        _ = try await run("post('groovy:click', { eventId: 'e-at-2', pageRef: 'p' }); setTimeout(function () { window.open('\(Self.clickURL)', '_blank'); }, 300); true", in: view)
        await eventually { listener.events.contains(.offerOpened(eventId: "e-at-2")) }
        XCTAssertEqual(opened.count, 2)
        // An open whose click never comes is dropped once the pairing window passes.
        _ = try await run("window.open('\(Self.clickURL)', '_blank'); true", in: view)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(opened.count, 2)
        // Without assistive technology the same sequence opens nothing: the residual the CTO
        // accepted exists only while a screen reader or switch access runs.
        view.assistiveTechnologyRunning = { false }
        _ = try await run("window.open('\(Self.clickURL)', '_blank'); setTimeout(function () { post('groovy:click', { eventId: 'e-no-at', pageRef: 'p' }); }, 200); true", in: view)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(opened.count, 2)
        XCTAssertFalse(listener.events.contains(.offerOpened(eventId: "e-no-at")))
    }

    func testAClicklessRefusalNeverTakesALaterTapsClick() async throws {
        // Copilot round 1 on slice 2: a script on the click URL with no `groovy:click` is refused
        // and held for a click that never comes; a real tap's open within the pairing window keeps
        // its own click's id, and the hold is dropped, never fed to the state machine.
        let view = makeView(recordOpens: true)
        await eventually { listener.events.contains(.loaded(250)) }
        _ = try await run("window.open('\(Self.clickURL)', '_blank'); true", in: view)
        try await Task.sleep(nanoseconds: 300_000_000)
        view.simulateTap()
        _ = try await run("post('groovy:click', { eventId: 'e-real', pageRef: 'p' }); window.open('\(Self.clickURL)', '_blank'); true", in: view)
        await eventually { listener.events.contains(.offerOpened(eventId: "e-real")) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(listener.events.filter { if case .offerOpened = $0 { return true } else { return false } },
                       [.offerOpened(eventId: "e-real")])
    }

    func testAHeldOfferWhoseClickNeverCameTakesNoLaterClick() async throws {
        // Under assistive technology the same: an expired hold is dropped, and the next open pairs
        // with its own click.
        let view = makeView(recordOpens: true)
        view.assistiveTechnologyRunning = { true }
        await eventually { listener.events.contains(.loaded(250)) }
        _ = try await run("window.open('\(Self.clickURL)', '_blank'); true", in: view)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(opened, [], "the hold expired")
        _ = try await run("window.open('\(Self.clickURL)', '_blank'); setTimeout(function () { post('groovy:click', { eventId: 'e-at', pageRef: 'p' }); }, 200); true", in: view)
        await eventually { listener.events.contains(.offerOpened(eventId: "e-at")) }
        XCTAssertEqual(opened.count, 1)
    }

    func testTheWidgetsStorageIsItsOwnAndSharedByItsViews() async throws {
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        let store = webView(of: view)?.configuration.websiteDataStore
        XCTAssertNotNil(store)
        XCTAssertFalse(store === WKWebsiteDataStore.default(), "never the app's default store")
        XCTAssertEqual(store?.isPersistent, false)
        // Unique values: the app's default store persists across test runs on this simulator.
        let stamp = String(Int(Date().timeIntervalSince1970))
        _ = try await run("localStorage.setItem('probe', 'widget-\(stamp)'); document.cookie = 'probe=widget-\(stamp)'; true", in: view)

        // A second widget view shares it (one token cache per process).
        let second = makeView()
        await eventually { listener.events.filter { $0 == .loaded(250) }.count == 2 }
        XCTAssertTrue(webView(of: second)?.configuration.websiteDataStore === store)
        let seen = try await run("localStorage.getItem('probe')", in: second) as? String
        XCTAssertEqual(seen, "widget-\(stamp)")

        // The app's own web content on the same origin sees none of it, nor the reverse.
        let appConfig = WKWebViewConfiguration()
        appConfig.websiteDataStore = .default()
        let appView = WKWebView(frame: .zero, configuration: appConfig)
        window.rootViewController?.view.addSubview(appView)
        appView.loadHTMLString("<html><body>app</body></html>", baseURL: URL(string: "https://widget-embed-dev.joingroovy.com/v1/example-publisher/frame.html"))
        await eventually { !appView.isLoading && appView.url != nil }
        let appSees = try await appView.evaluateJavaScript("(localStorage.getItem('probe') || '') + '|' + document.cookie") as? String
        XCTAssertFalse(appSees?.contains("widget-\(stamp)") ?? true, "the app's store never sees the widget's values: \(appSees ?? "")")
        _ = try await appView.evaluateJavaScript("localStorage.setItem('probe', 'app-\(stamp)'); true")
        let widgetSees = try await run("localStorage.getItem('probe')", in: view) as? String
        XCTAssertEqual(widgetSees, "widget-\(stamp)")
        appView.removeFromSuperview()
    }

    func testCameraMicrophoneAndLocationAreRefusedWithoutAPrompt() async throws {
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        // The lockdown script removed the entry points: nothing to prompt for.
        let probe = try await run("window.__probe(window)", in: view) as? String
        XCTAssertEqual(probe, "undefined,undefined,undefined")
        let locked = try await run("""
        (function () {
          try { Object.defineProperty(navigator, 'geolocation', { value: {}, configurable: true }); } catch (e) {}
          try { Navigator.prototype.geolocation = {}; } catch (e) {}
          try { navigator.mediaDevices = { getUserMedia: function () {} }; } catch (e) {}
          return window.__probe(window);
        })()
        """, in: view) as? String
        XCTAssertEqual(locked, "undefined,undefined,undefined", "the page cannot put them back")
        // A file input (which can offer the camera where no native delegate refuses it, iOS before
        // 18.4) opens no chooser: a click on it is cancelled, `click()` and `showPicker()` do nothing.
        let fileInput = try await run("""
        (function () {
          var i = document.createElement('input'); i.type = 'file'; document.body.appendChild(i);
          var cancelled = !i.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
          var clicked = false; i.addEventListener('click', function () { clicked = true; });
          i.click();
          var picker; try { picker = String(i.showPicker()); } catch (e) { picker = 'threw'; }
          var text = document.createElement('input'); text.type = 'text'; document.body.appendChild(text);
          var textClicked = false; text.addEventListener('click', function () { textClicked = true; }); text.click();
          return [cancelled, clicked, picker, textClicked].join(',');
        })()
        """, in: view) as? String
        XCTAssertEqual(fileInput, "true,false,undefined,true")
        // Copilot round 2: the guard runs first on the window, sees through open and closed shadow
        // roots, reads the native `type` (an own property cannot disguise the input), and survives
        // `document.open()`.
        let hardened = try await run("""
        (function () {
          var out = [];
          function cancelled(input) { return !input.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true })); }
          // A page listener on the window, capture phase, that stops propagation: registered after the guard, it runs after it.
          window.addEventListener('click', function (e) { e.stopImmediatePropagation(); }, true);
          var plain = document.createElement('input'); plain.type = 'file'; document.body.appendChild(plain);
          out.push(cancelled(plain));
          var host = document.createElement('div'); document.body.appendChild(host);
          var openRoot = host.attachShadow({ mode: 'open' });
          var inOpen = document.createElement('input'); inOpen.type = 'file'; openRoot.appendChild(inOpen);
          out.push(cancelled(inOpen));
          var host2 = document.createElement('div'); document.body.appendChild(host2);
          var closedRoot = host2.attachShadow({ mode: 'closed' });
          var inClosed = document.createElement('input'); inClosed.type = 'file'; closedRoot.appendChild(inClosed);
          out.push(cancelled(inClosed));
          var spoofed = document.createElement('input'); spoofed.setAttribute('type', 'file');
          Object.defineProperty(spoofed, 'type', { value: 'text', configurable: true }); document.body.appendChild(spoofed);
          out.push(cancelled(spoofed));
          var frame = document.createElement('iframe'); document.body.appendChild(frame);
          frame.contentDocument.open(); frame.contentDocument.write('<input id="f" type="file">'); frame.contentDocument.close();
          var inFrame = frame.contentDocument.getElementById('f');
          out.push(!inFrame.dispatchEvent(new frame.contentWindow.MouseEvent('click', { bubbles: true, cancelable: true })));
          return out.join(',');
        })()
        """, in: view) as? String
        XCTAssertEqual(hardened, "true,true,true,true,true")
        // Copilot round 3: a page that replaces the event methods, the `target` getter, the
        // `instanceof` hook, `addEventListener` or `Function.prototype.call` after the fact changes
        // nothing: everything the guard relies on was captured at document start.
        let mutated = try await run("""
        (function () {
          Event.prototype.composedPath = function () { return []; };
          Event.prototype.preventDefault = function () {};
          Object.defineProperty(Event.prototype, 'target', { get: function () { return document.body; }, configurable: true });
          Object.defineProperty(HTMLInputElement, Symbol.hasInstance, { value: function () { return false; } });
          EventTarget.prototype.addEventListener = function () {};
          Function.prototype.call = function () { throw new Error('no call'); };
          Function.prototype.apply = function () { throw new Error('no apply'); };
          var i = document.createElement('input'); i.type = 'file'; document.body.appendChild(i);
          var cancelled = !i.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
          var host = document.createElement('div'); document.body.appendChild(host);
          var root = host.attachShadow({ mode: 'closed' });
          var inner = document.createElement('input'); inner.type = 'file'; root.appendChild(inner);
          var innerCancelled = !inner.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true }));
          var clicked = false; i.onclick = function () { clicked = true; }; i.click();
          return [cancelled, innerCancelled, clicked].join(',');
        })()
        """, in: view) as? String
        XCTAssertEqual(mutated, "true,true,false")
        XCTAssertNil(window.rootViewController?.presentedViewController)
    }

    func testLocationIsAbsentInEveryFrameIncludingOnesCreatedLater() async throws {
        let view = makeView()
        await eventually { listener.events.contains(.loaded(250)) }
        let probes = try await run("""
        (function () {
          var out = {};
          var blank = document.createElement('iframe'); document.body.appendChild(blank);
          out.blank = window.__probe(blank.contentWindow);
          var written = document.createElement('iframe'); document.body.appendChild(written);
          written.contentDocument.open(); written.contentDocument.write('<p>w</p>'); written.contentDocument.close();
          out.written = window.__probe(written.contentWindow);
          return JSON.stringify(out);
        })()
        """, in: view) as? String
        XCTAssertEqual(probes, #"{"blank":"undefined,undefined,undefined","written":"undefined,undefined,undefined"}"#)
        // A srcdoc frame, read once it has loaded.
        _ = try await run("""
        var s = document.createElement('iframe'); s.id = 'srcdoc'; s.srcdoc = '<p>s</p>';
        s.onload = function () { window.__srcdoc = window.__probe(s.contentWindow); };
        document.body.appendChild(s); true
        """, in: view)
        for _ in 0..<100 where ((try? await run("window.__srcdoc || ''", in: view)) as? String ?? "") == "" {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let srcdoc = try await run("window.__srcdoc", in: view) as? String
        XCTAssertEqual(srcdoc, "undefined,undefined,undefined")
    }

    func testTeardownReleasesTheView() async throws {
        weak var released: GroovyWidgetView?
        do {
            let view = makeView()
            released = view
            await eventually { listener.events.contains(.loaded(250)) }
            view.removeFromSuperview()
        }
        await eventually { released == nil }
        XCTAssertNil(released, "the WebView's message handler must not keep the view alive")
    }
}

@MainActor
final class RecordingListener: GroovyWidgetListener {
    private(set) var events: [GroovyWidgetEvent] = []

    func groovyWidget(_ view: GroovyWidgetView, didLoadWithHeight height: CGFloat) { events.append(.loaded(height)) }
    func groovyWidget(_ view: GroovyWidgetView, didResizeTo height: CGFloat) { events.append(.resized(height)) }
    func groovyWidget(_ view: GroovyWidgetView, didOpenOfferWithEventId eventId: String) { events.append(.offerOpened(eventId: eventId)) }
    func groovyWidgetDidDismiss(_ view: GroovyWidgetView) { events.append(.dismissed) }
    func groovyWidget(_ view: GroovyWidgetView, isEmpty reason: GroovyEmptyReason) { events.append(.empty(reason)) }
}
