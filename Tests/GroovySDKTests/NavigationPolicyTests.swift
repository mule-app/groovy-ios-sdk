import XCTest
@_spi(GroovyInternal) @testable import GroovySDK

/// T027 and spec 230 T015: which requests from the widget's WebView open, load or are cancelled
/// (contracts/navigation-rule.md): the click URL and any other page open only after a native tap.
final class NavigationPolicyTests: XCTestCase {
    private let dev = EnvironmentHosts.of(.dev)

    private enum Target { case main, sub, window }

    /// How many times the rule asked the tap gate in the last `decide`.
    private var asked = 0

    /// The marker of the configured load (spec 230, PR 976): publisher `x`, account `GR-X`.
    private let marker = WidgetURL.marker(for: WidgetConfiguration(publisherId: "x", accountId: " GR-X ", environment: .dev))
    /// The widget document that load shows: the one address the main frame may stay on.
    private let widget = "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?account_id=GR-X&sdk_platform=ios&sdk_version=1.0.1&bridge=1"

    private func decide(_ url: String, from source: Target = .main, to target: Target = .main, gesture tapped: Bool = false,
                        hosts: EnvironmentHosts? = nil) -> NavigationDecision {
        let targetIsMain: Bool? = target == .window ? nil : target == .main
        asked = 0
        return NavigationPolicy.decide(url: URL(string: url), sourceIsMainFrame: source == .main,
                                       targetIsMainFrame: targetIsMain,
                                       tapped: { self.asked += 1; return tapped }, hosts: hosts ?? dev, marker: marker)
    }

    // MARK: - Spec 230 T043: the main frame stays only on a widget document (the SDK marker)

    func testTheMarkerIsWhatTheBuilderSends() throws {
        XCTAssertEqual(marker, SdkMarker(platform: "ios", accountId: "GR-X", path: "/v1/x/frame.html"))
        XCTAssertEqual(WidgetURL.platform, "ios")
        let built = try XCTUnwrap(WidgetURL.build(WidgetConfiguration(publisherId: "x", accountId: " GR-X ", environment: .dev)))
        XCTAssertTrue(NavigationPolicy.isWidgetDocument(built, hosts: dev, marker: marker), "the address the SDK loads is a widget document")
    }

    func testAWidgetDocumentIsAllowedWhateverTheOtherParameters() throws {
        XCTAssertEqual(decide(widget), .allow)
        XCTAssertEqual(decide(widget + "&placement=tracking.top&ad_id=abc#frag"), .allow)
        XCTAssertEqual(decide("https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=ios&account_id=GR-X"), .allow)
        // Decoded as URLSearchParams decodes: an escaped value, an escaped name, `+` as a space.
        XCTAssertEqual(decide("https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=io%73&account%5Fid=GR%2DX"), .allow)
        let spaced = WidgetURL.marker(for: WidgetConfiguration(publisherId: "x", accountId: "GR X", environment: .dev))
        XCTAssertTrue(NavigationPolicy.isWidgetDocument(URL(string: "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=ios&account_id=GR+X")!, hosts: dev, marker: spaced))
        XCTAssertTrue(NavigationPolicy.isWidgetDocument(URL(string: "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=ios&account_id=GR%20X")!, hosts: dev, marker: spaced))
        XCTAssertEqual(asked, 0, "never asks the gate")
    }

    func testTheWidgetHostWithoutTheMarkerIsAnExternalPage() throws {
        let cases = [
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=ios",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=android&account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=ios&account_id=GR-Y",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=ios&account_id=",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=ios%20&account_id=GR-X",
            // The first pair of a name counts, as URLSearchParams.get reads it.
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=web&sdk_platform=ios&account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk%5Fplatform=web&sdk_platform=ios&account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?account%5Fid=GR-Y&sdk_platform=ios&account_id=GR-X",
            // (A malformed escape such as `%zz` forms no `URL` on iOS, so it never reaches the rule;
            // the reader's own case below keeps it literal, as the contract says.)
            // The marker after `#` is not in the query.
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html#?sdk_platform=ios&account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?a=1#sdk_platform=ios&account_id=GR-X",
            // A `+` is a space, not the `%2B` the builder sends for a plus.
            "https://widget-embed-dev.joingroovy.com/v1/x/frame.html?sdk_platform=ios&account_id=GR+X",
            // Another path on the host: another publisher's frame, an older object, a dot segment.
            "https://widget-embed-dev.joingroovy.com/v1/y/frame.html?sdk_platform=ios&account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/latest/x/iframe/index.html?sdk_platform=ios&account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/v1/x/%66rame.html?sdk_platform=ios&account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/v1/x/../x/frame.html?sdk_platform=ios&account_id=GR-X",
            "https://widget-embed-dev.joingroovy.com/?sdk_platform=ios&account_id=GR-X",
        ]
        for url in cases {
            XCTAssertEqual(decide(url), .refuseLink, url)
            XCTAssertEqual(decide(url, gesture: true), .openLink, url)
        }
        XCTAssertEqual(decide("https://widget-embed-dev.joingroovy.com/v1/x/frame.html?a=1&sdk_platform=ios&account_id=GR-X"), .allow,
                       "the order of the pairs does not matter")
    }

    func testTheQueryReaderReadsLikeURLSearchParams() throws {
        XCTAssertEqual(QueryReader.firstValue(in: "a=1&b=2&a=3", named: "a"), "1")
        XCTAssertEqual(QueryReader.firstValue(in: "a&b=2", named: "a"), "")
        XCTAssertEqual(QueryReader.firstValue(in: "a=x%20y+z%2B", named: "a"), "x y z+")
        XCTAssertEqual(QueryReader.firstValue(in: "%61=%7a", named: "a"), "z")
        XCTAssertEqual(QueryReader.firstValue(in: "a=%zz%41%", named: "a"), "%zzA%", "malformed escapes stay literal")
        XCTAssertEqual(QueryReader.firstValue(in: "a=1=2", named: "a"), "1=2", "split at the first `=` only")
        XCTAssertEqual(QueryReader.firstValue(in: "&&a=1", named: "a"), "1")
        XCTAssertNil(QueryReader.firstValue(in: "b=1", named: "a"))
        XCTAssertNil(QueryReader.firstValue(in: nil, named: "a"))
        XCTAssertNil(QueryReader.firstValue(in: "", named: "a"))
    }

    func testTheClickURLOpensOnlyAfterATap() throws {
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", to: .window, gesture: true), .openOffer)
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", gesture: true), .openOffer)
        // The contract's "no user info": with it the URL is not the click host's, so it is a link.
        XCTAssertEqual(decide("https://x@api-dev.joingroovy.com/trk/c?dest=x", gesture: true), .openLink)
        XCTAssertEqual(decide("https://x@widget-embed-dev.joingroovy.com/v1/x/frame.html", gesture: true), .openLink)
        XCTAssertEqual(decide("https://x@widget-embed-dev.joingroovy.com/v1/x/frame.html"), .refuseLink)
    }

    func testTheClickURLWithoutATapIsARefusedOffer() throws {
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", to: .window), .refuseOffer)
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x"), .refuseOffer)
        // Not the click URL: refused as a link, never as an offer.
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/context", to: .window), .refuseLink)
        XCTAssertEqual(decide("https://advertiser.example/offer", to: .window), .refuseLink)
        // A sub-frame's click URL is cancelled before the gate matters.
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", from: .sub, to: .main, gesture: true), .openLink)
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", from: .sub, to: .window, gesture: true), .cancel)
    }

    func testTheGateIsAskedOnlyWhenAPageWouldOpen() throws {
        _ = decide("https://api-dev.joingroovy.com/trk/c?dest=x", gesture: true)
        XCTAssertEqual(asked, 1)
        _ = decide("https://advertiser.example/offer", to: .window)
        XCTAssertEqual(asked, 1)
        // Never for what the WebView keeps, a sub-frame's window, a bad scheme or no URL.
        _ = decide(widget, gesture: true)
        XCTAssertEqual(asked, 0)
        _ = decide("about:blank", gesture: true)
        XCTAssertEqual(asked, 0)
        _ = decide("https://advertiser.example/", from: .sub, to: .sub, gesture: true)
        XCTAssertEqual(asked, 0)
        _ = decide("https://advertiser.example/", from: .sub, to: .window, gesture: true)
        XCTAssertEqual(asked, 0)
        _ = decide("javascript:alert(1)", gesture: true)
        XCTAssertEqual(asked, 0)
        asked = 0
        _ = NavigationPolicy.decide(url: nil, sourceIsMainFrame: true, targetIsMainFrame: nil, tapped: { self.asked += 1; return true }, hosts: dev, marker: marker)
        XCTAssertEqual(asked, 0)
    }

    func testAllowsTheWidgetHost() throws {
        XCTAssertEqual(decide(widget + "&a=1"), .allow)
        // Since PR 976: the widget host without the SDK marker is an external page, never "the widget".
        XCTAssertEqual(decide("https://widget-embed-dev.joingroovy.com/v1/x/frame.html?a=1"), .refuseLink)
        XCTAssertEqual(decide("about:blank"), .allow)
        XCTAssertNotEqual(decide("http://widget-embed-dev.joingroovy.com/v1/x/frame.html"), .allow)
        XCTAssertNotEqual(decide("https://widget-embed-dev.joingroovy.com.evil.example/"), .allow)
        XCTAssertNotEqual(decide("https://widget-embed-dev.joingroovy.com:8443/"), .allow)
        // A new window is never the widget, even on its host.
        XCTAssertEqual(decide("https://widget-embed-dev.joingroovy.com/x", to: .window), .refuseLink)
    }

    func testOpensTheClickURLFromTheMainFrameAfterATap() throws {
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", to: .window, gesture: true), .openOffer)
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", gesture: true), .openOffer)
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/context", to: .window, gesture: true), .openLink)
        XCTAssertEqual(decide("http://api-dev.joingroovy.com/trk/c?dest=x", to: .window, gesture: true), .openLink)
    }

    func testRefusesTheClickURLFromASubFrameWindowRequest() throws {
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", from: .sub, to: .window), .cancel)
        XCTAssertEqual(decide("https://advertiser.example/", from: .sub, to: .window, gesture: true), .cancel)
    }

    func testASubFramesTopNavigationNeverLeavesTheWidgetUnasked() throws {
        // A sub-frame navigating the top frame is judged as a main-frame navigation...
        XCTAssertEqual(decide("https://phish.example/login", from: .sub, to: .main), .refuseLink)
        // ...it never opens an offer without the main frame asking for it...
        XCTAssertEqual(decide("https://api-dev.joingroovy.com/trk/c?dest=x", from: .sub, to: .main), .refuseLink)
        // ...and after a tap it opens in the sheet, never in the SDK's own WebView.
        XCTAssertEqual(decide("https://advertiser.example/", from: .sub, to: .main, gesture: true), .openLink)
    }

    func testOpensOtherLinksOnlyAfterAGesture() throws {
        XCTAssertEqual(decide("https://advertiser.example/offer", gesture: true), .openLink)
        XCTAssertEqual(decide("https://advertiser.example/offer", to: .window, gesture: true), .openLink)
        XCTAssertEqual(decide("https://advertiser.example/offer"), .refuseLink)
        XCTAssertEqual(decide("https://advertiser.example/offer", to: .window), .refuseLink)
    }

    func testCancelsNonHTTPSchemes() throws {
        for url in ["javascript:alert(1)", "tel:123", "mailto:a@b.c", "file:///etc/passwd", "itms-apps://x", "data:text/html,x"] {
            XCTAssertEqual(decide(url, gesture: true), .cancel, url)
        }
        XCTAssertEqual(NavigationPolicy.decide(url: nil, sourceIsMainFrame: true, targetIsMainFrame: nil,
                                               tapped: { true }, hosts: dev, marker: marker), .cancel)
    }

    func testLeavesSubFrameNavigationsToTheWebView() throws {
        XCTAssertEqual(decide("https://player.example/embed", from: .sub, to: .sub), .allow)
        XCTAssertEqual(decide("https://player.example/embed", from: .main, to: .sub), .allow)
    }

    func testClickHostIsPerEnvironment() throws {
        XCTAssertEqual(decide("https://api.joingroovy.com/trk/c?dest=x", to: .window), .refuseLink)
        XCTAssertEqual(decide("https://api.joingroovy.com/trk/c?dest=x", to: .window, gesture: true, hosts: .of(.production)), .openOffer)
        XCTAssertEqual(decide("https://api.joingroovy.com/trk/c?dest=x", to: .window, hosts: .of(.production)), .refuseOffer)
    }
}
