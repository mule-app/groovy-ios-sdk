import WebKit
import XCTest

/// Platform facts the bridge relies on, checked on the real WKWebView (research R20): a message
/// posted from the SDK's own content world reaches the page as one from its own window and origin,
/// and the page's own `groovy:*` messages reach a listener in that world.
@MainActor
final class ContentWorldProbeTests: XCTestCase {
    private let base = URL(string: "https://widget-embed-dev.joingroovy.com/v1/probe/frame.html")!

    private func load(_ html: String, in webView: WKWebView) async throws {
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: base)
        try await delegate.wait()
    }

    func testAPostFromTheSDKWorldReachesThePageAsItsOwnWindowAndOrigin() async throws {
        let world = WKContentWorld.world(name: "GroovySDKProbe")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        try await load("""
        <html><body><script>
          window.__seen = [];
          window.addEventListener("message", function (e) {
            window.__seen.push({ source: e.source === window, parent: e.source === window.parent,
                                 origin: e.origin, type: e.data && e.data.type });
          });
        </script></body></html>
        """, in: webView)

        _ = try await webView.callAsyncJavaScript(
            "window.postMessage({ type: 'groovy:context', payload: { retailer: 'acme' } }, location.origin); return 1;",
            contentWorld: world)
        try await Task.sleep(nanoseconds: 300_000_000)
        let seen = try await webView.evaluateJavaScript("JSON.stringify(window.__seen)") as? String
        let expected = #"[{"source":true,"parent":true,"origin":"https://widget-embed-dev.joingroovy.com","type":"groovy:context"}]"#
        XCTAssertEqual(seen, expected)
    }

    func testThePagesMessagesReachAListenerInTheSDKWorld() async throws {
        let world = WKContentWorld.world(name: "GroovySDKProbe2")
        let controller = WKUserContentController()
        let sink = MessageSink()
        controller.add(sink, contentWorld: world, name: "probe")
        controller.addUserScript(WKUserScript(source: """
        window.addEventListener("message", function (event) {
          if (event.source !== window || event.origin !== location.origin) { return; }
          window.webkit.messageHandlers.probe.postMessage(JSON.stringify(event.data));
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), configuration: config)
        try await load("""
        <html><body><script>
          window.postMessage({ type: "groovy:ready", payload: { height: 10 } }, location.origin);
          // The page cannot reach the SDK's handler: it lives in another content world.
          window.__pageSeesHandler = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.probe);
        </script></body></html>
        """, in: webView)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sink.bodies, [#"{"type":"groovy:ready","payload":{"height":10}}"#])
        let pageSees = try await webView.evaluateJavaScript("window.__pageSeesHandler") as? Bool
        XCTAssertEqual(pageSees, false)
    }
}

final class MessageSink: NSObject, WKScriptMessageHandler {
    private(set) var bodies: [String] = []
    private(set) var frames: [WKFrameInfo] = []

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        bodies.append(message.body as? String ?? "")
        frames.append(message.frameInfo)
    }
}

final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
