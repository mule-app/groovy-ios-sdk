import Foundation

/// The script injected at document start, in the main frame only, in the SDK's own content world
/// (research R20). Frozen per release in `modules/widget/__tests__/sdk-bridge/fixtures/` and run
/// by the widget's tests against every later widget (research R11): never change it without a new
/// fixture, and never in a way an older widget would not answer.
///
/// It forwards the widget's own `groovy:*` messages to the native `groovy` handler: only those the
/// widget posted to this window (`event.source === window`, `event.origin === location.origin`),
/// so a message a sub-frame posts to its parent is never forwarded, and never `groovy:context`,
/// which is the SDK's own message (the app's context).
enum BridgeScript {
    static let handlerName = "groovy"

    static let source = """
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.groovy;
      if (!handler) { return; }
      window.addEventListener("message", function (event) {
        if (event.source !== window || event.origin !== location.origin) { return; }
        var data = event.data;
        if (!data || typeof data.type !== "string" || data.type.indexOf("groovy:") !== 0) { return; }
        if (data.type === "groovy:context") { return; }
        try { handler.postMessage(JSON.stringify(data)); } catch (e) { /* not serialisable: not forwarded */ }
      });
    })();
    """

    /// The JavaScript that delivers the app's context to the widget, run in the main frame:
    /// `window.postMessage({type: "groovy:context", payload: <context>}, "https://<widget host>")`.
    /// The target is the widget's own origin, fixed, not `location.origin`: if the page were ever
    /// somewhere else, the browser drops the message instead of handing it the app's context.
    /// `contextJSON` is produced by `ContextEncoder`, never by concatenating app values.
    static func deliverContext(_ contextJSON: String, widgetHost: String) -> String {
        let origin = "\"https://\(widgetHost)\""
        return "window.postMessage({ type: \"groovy:context\", payload: \(contextJSON) }, \(origin)); true;"
    }
}

/// Encodes `GroovyContext` as the `groovy:context` payload (data-model "Context"): the known keys
/// when set and the custom keys, never a user ID (spec 230 FR-006: a custom key spelled `userId`,
/// `userID`, `user_id` or `userid` is dropped with a debug line naming the key, never its value).
/// Known keys win over a custom key of the same name. A non-finite number is dropped (JSON has
/// none; encoding one would raise an exception the app could not catch).
enum ContextEncoder {
    /// The spellings the hosted widget and the router recognise as a user ID.
    static let userIdKeys: Set<String> = ["userId", "userID", "user_id", "userid"]

    /// The payload without any user-ID key.
    static func withoutUserIdKeys(_ payload: [String: Any]) -> [String: Any] {
        var clean = payload
        for key in userIdKeys where clean.removeValue(forKey: key) != nil {
            Log.debug("a custom context key is a user ID (\(key)): not sent")
        }
        return clean
    }

    static func payload(_ context: GroovyContext) -> [String: Any] {
        var payload: [String: Any] = [:]
        for (key, value) in context.custom {
            switch value {
            case .string(let string): payload[key] = string
            case .bool(let bool): payload[key] = bool
            case .number(let number):
                if number.isFinite {
                    payload[key] = number
                } else {
                    Log.debug("a custom context number is not finite: not sent")
                }
            }
        }
        if let retailer = context.retailer { payload["retailer"] = retailer }
        if let parcelStatus = context.parcelStatus { payload["parcelStatus"] = parcelStatus }
        if let country = context.country { payload["country"] = country }
        return withoutUserIdKeys(payload)
    }

    /// JSON text of `payload(context)`, sorted keys; `{}` if it could not be encoded.
    static func json(_ context: GroovyContext) -> String {
        let payload = payload(context)
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        // `</script>` cannot end anything here (the text is evaluated, not embedded in HTML), but
        // U+2028 and U+2029 are line terminators in older JavaScript string literals.
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
