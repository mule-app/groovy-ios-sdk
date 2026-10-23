import XCTest
@_spi(GroovyInternal) @testable import GroovySDK

/// T027: which requests from the widget's WebView open, load or are cancelled (research R6).
final class NavigationPolicyTests: XCTestCase {
    private let dev = EnvironmentHosts.of(.dev)

    private enum Target { case main, sub, window }

    private func decide(_ url: String, from source: Target = .main, to target: Target = .main, gesture: Bool = false,
                        hosts: EnvironmentHosts? = nil) -> NavigationDecision {
        let targetIsMain: Bool? = target == .window ? nil : target == .main
        return NavigationPolicy.decide(url: URL(string: url), sourceIsMainFrame: source == .main,
                                       targetIsMainFrame: targetIsMain, userActivated: gesture, hosts: hosts ?? dev)
    }

    func testAllowsTheWidgetHost() throws {
        XCTAssertEqual(decide("https://widget-embed-dev.joingroovy.com/v1/x/frame.html?a=1"), .allow)
        XCTAssertEqual(decide("about:blank"), .allow)
        XCTAssertNotEqual(decide("http://widget-embed-dev.joingroovy.com/v1/x/frame.html"), .allow)
        XCTAssertNotEqual(decide("https://widget-embed-dev.joingroovy.com.evil.example/"), .allow)
        XCTAssertNotEqual(decide("https://widget-embed-dev.joingroovy.com:8443/"), .allow)
        // A new window is never the widget, even on its host.
        XCTAssertEqual(decide("https://widget-embed-dev.joingroovy.com/x", to: .window), .cancel)
    }

    func testOpensTheClickURLFromTheMainFrameWithoutAGesture() throws {
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", to: .window), .openOffer)
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x"), .openOffer)
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/context", to: .window), .cancel)
        XCTAssertEqual(decide("http://api-dev.joingroovy.com/trk/c?dest=x", to: .window), .cancel)
    }

    func testRefusesTheClickURLFromASubFrameWindowRequest() throws {
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", from: .sub, to: .window), .cancel)
        XCTAssertEqual(decide("https://advertiser.example/", from: .sub, to: .window, gesture: true), .cancel)
    }

    func testASubFramesTopNavigationNeverLeavesTheWidgetUnasked() throws {
        // A sub-frame navigating the top frame is judged as a main-frame navigation...
        XCTAssertEqual(decide("https://phish.example/login", from: .sub, to: .main), .cancel)
        // ...it never opens an offer without the main frame asking for it...
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", from: .sub, to: .main), .cancel)
        // ...and after a tap it opens in the sheet, never in the SDK's own WebView.
        XCTAssertEqual(decide("https://advertiser.example/", from: .sub, to: .main, gesture: true), .openLink)
    }

    func testOpensOtherLinksOnlyAfterAGesture() throws {
        XCTAssertEqual(decide("https://advertiser.example/offer", gesture: true), .openLink)
        XCTAssertEqual(decide("https://advertiser.example/offer", to: .window, gesture: true), .openLink)
        XCTAssertEqual(decide("https://advertiser.example/offer"), .cancel)
        XCTAssertEqual(decide("https://advertiser.example/offer", to: .window), .cancel)
    }

    func testCancelsNonHTTPSchemes() throws {
        for url in ["javascript:alert(1)", "tel:123", "mailto:a@b.c", "file:///etc/passwd", "itms-apps://x", "data:text/html,x"] {
            XCTAssertEqual(decide(url, gesture: true), .cancel, url)
        }
        XCTAssertEqual(NavigationPolicy.decide(url: nil, sourceIsMainFrame: true, targetIsMainFrame: nil,
                                               userActivated: true, hosts: dev), .cancel)
    }

    func testLeavesSubFrameNavigationsToTheWebView() throws {
        XCTAssertEqual(decide("https://player.example/embed", from: .sub, to: .sub), .allow)
        XCTAssertEqual(decide("https://player.example/embed", from: .main, to: .sub), .allow)
    }

    func testClickHostIsPerEnvironment() throws {
        XCTAssertEqual(decide("https://api.joingroovy.com/trk/c?dest=x", to: .window), .cancel)
        XCTAssertEqual(decide("https://api.joingroovy.com/trk/c?dest=x", to: .window, hosts: .of(.production)), .openOffer)
    }
}
