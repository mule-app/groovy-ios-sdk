import Foundation

/// What to do with a navigation or a window request from the widget's WebView (research R6).
enum NavigationDecision: Equatable {
    /// Let the WebView load it.
    case allow
    /// Cancel it and open the URL in the in-app browser sheet, as an offer.
    case openOffer
    /// Cancel it and open the URL in the sheet, not as an offer (a link the visitor tapped).
    case openLink
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
    ///
    /// Rules:
    /// - A sub-frame loading inside itself is left to the WebView.
    /// - The main frame may stay on the widget host over https (and on `about:blank`).
    /// - `https://<click host>/trk/c` opens as an offer without a tap, only when the main frame
    ///   asked for it (a top navigation or a window).
    /// - Anything else that would leave the widget (the main frame elsewhere, or any new window)
    ///   opens in the sheet only after a tap and only for http(s); otherwise it is cancelled. A
    ///   sub-frame's window request is always cancelled.
    static func decide(url: URL?, sourceIsMainFrame: Bool, targetIsMainFrame: Bool?, userActivated: Bool,
                       hosts: EnvironmentHosts) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if targetIsMainFrame == false { return .allow }
        let isWindow = targetIsMainFrame == nil
        if isWindow && !sourceIsMainFrame { return .cancel }

        let host = url.host?.lowercased()
        let defaultPort = url.port == nil || url.port == 443
        if !isWindow {
            if scheme == "about" && url.absoluteString == "about:blank" { return .allow }
            if scheme == "https" && host == hosts.widgetHost && defaultPort { return .allow }
        }
        if scheme == "https" && host == hosts.clickHost && defaultPort && url.path == "/trk/c" && sourceIsMainFrame {
            return .openOffer
        }
        if (scheme == "https" || scheme == "http") && userActivated {
            return .openLink
        }
        return .cancel
    }
}
