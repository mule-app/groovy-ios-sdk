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
    </script></body></html>
    """

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

    private func makeView(page: String = page, context: GroovyContext = GroovyContext(retailer: "asos", userId: "u-1")) -> GroovyWidgetView {
        let view = GroovyWidgetView(publisherId: "example-publisher", accountId: "GR-EXAMPLE", initialHeight: 120, context: context)
        view.testPage = { _ in page }
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
        let contexts = try await run("JSON.stringify(window.__contexts)", in: view) as? String
        XCTAssertEqual(contexts, #"[{"retailer":"asos","userId":"u-1"}]"#)

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
