import Foundation

/// What to do with a navigation or a window request from the widget's WebView (spec 230,
/// contracts/navigation-rule.md; spec 222 research R6 for the frame rules).
enum NavigationDecision: Equatable {
    /// Let the WebView load it.
    case allow
    /// Cancel it and open the URL in the in-app browser sheet, as an offer.
    case openOffer
    /// Cancel it and open the URL in the sheet, not as an offer (a link the visitor tapped).
    case openLink
    /// The click URL with no tap: cancelled, and fed to the state machine as a refused offer so its
    /// `groovy:click` is consumed and a later real tap pairs with its own click.
    case refuseOffer
    /// Any other http(s) page with no tap: cancelled, with the debug line; nothing for the state
    /// machine (no `groovy:click` announces a link).
    case refuseLink
    /// Cancel it.
    case cancel
}

enum NavigationPolicy {
    /// Decide for one request.
    ///
    /// - Parameters:
    ///   - sourceIsMainFrame: the frame that asked for it is the main frame.
    ///   - targetIsMainFrame: where it would load: the main frame (`true`), a sub-frame (`false`),
    ///     or a new window (`nil`, `window.open` or `target=_blank`).
    ///   - tapped: the tap gate's answer, asked at most once and only when the request would
    ///     otherwise open a page (so a cancelled request never consumes a tap).
    ///   - marker: the SDK marker of the configured load (`WidgetURL.marker`), which tells a widget
    ///     document apart from any other page of the widget host.
    ///
    /// Rules (contracts/navigation-rule.md):
    /// - A sub-frame loading inside itself is left to the WebView.
    /// - The main frame may stay on a widget document (`isWidgetDocument`: the widget host over
    ///   https, default port, no user info, the marker's path and query) and on `about:blank`; any
    ///   other address of the widget host is judged as an external page below.
    /// - `https://<click host>/trk/c` (default port, no user info) from the main frame, as a top
    ///   navigation or a window, opens as an offer only when tapped; without a tap it is
    ///   `refuseOffer`.
    /// - Anything else that would leave the widget (the main frame elsewhere, or any new window)
    ///   opens in the sheet only when tapped and only for http(s); otherwise it is cancelled. A
    ///   sub-frame's window request is always cancelled.
    static func decide(url: URL?, sourceIsMainFrame: Bool, targetIsMainFrame: Bool?, tapped: () -> Bool,
                       hosts: EnvironmentHosts, marker: SdkMarker) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if targetIsMainFrame == false { return .allow }
        let isWindow = targetIsMainFrame == nil
        if isWindow && !sourceIsMainFrame { return .cancel }

        let host = url.host?.lowercased()
        let defaultPort = url.port == nil || url.port == 443
        let noUserInfo = url.user == nil && url.password == nil
        if !isWindow {
            if scheme == "about" && url.absoluteString == "about:blank" { return .allow }
            if isWidgetDocument(url, hosts: hosts, marker: marker) { return .allow }
        }
        if scheme == "https" && host == hosts.clickHost && defaultPort && noUserInfo && url.path == "/trk/c" && sourceIsMainFrame {
            return tapped() ? .openOffer : .refuseOffer
        }
        if scheme == "https" || scheme == "http" {
            return tapped() ? .openLink : .refuseLink
        }
        return .cancel
    }

    /// Spec 230 (the CTO's decision on PR 976): whether `url` is a widget document, the one kind of
    /// page the main frame may hold: https on the widget host at the default port with no user
    /// info, on the marker's path, whose query's first `sdk_platform` is the marker's platform and
    /// first `account_id` the marker's account ID. Any other address of the widget host is an
    /// external page to the rule, so a navigation that drops the marker can never load the hosted
    /// page in web mode (the RUM script, pixels, a 1.0.0 build's user ID) inside the app
    /// (contracts/navigation-rule.md).
    static func isWidgetDocument(_ url: URL, hosts: EnvironmentHosts, marker: SdkMarker) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == hosts.widgetHost,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == marker.path else { return false }
        let query = components.percentEncodedQuery
        return QueryReader.firstValue(in: query, named: "sdk_platform") == marker.platform
            && QueryReader.firstValue(in: query, named: "account_id") == marker.accountId
    }
}

/// Reads a raw query the way the widget's `URLSearchParams.get` does, so the SDK and the page
/// agree on what an address says (contracts/navigation-rule.md "marker"): pairs split on `&`, a
/// pair at its first `=`, the name and the value percent-decoded with `+` as a space, the first
/// pair of a name taken. A malformed escape is kept literally, as the WHATWG decoder keeps it,
/// and its pair still counts. Never `URLComponents.queryItems`, which keeps `+`.
enum QueryReader {
    static func firstValue(in rawQuery: String?, named name: String) -> String? {
        guard let rawQuery else { return nil }
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard decode(parts[0]) == name else { continue }
            return decode(parts.count > 1 ? parts[1] : "")
        }
        return nil
    }

    static func decode<S: StringProtocol>(_ encoded: S) -> String {
        var bytes: [UInt8] = []
        let input = Array(encoded.utf8)
        var i = 0
        while i < input.count {
            let byte = input[i]
            if byte == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " "))
                i += 1
            } else if byte == UInt8(ascii: "%"), i + 2 < input.count,
                      let high = hexValue(input[i + 1]), let low = hexValue(input[i + 2]) {
                bytes.append(high << 4 | low)
                i += 3
            } else {
                bytes.append(byte)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
