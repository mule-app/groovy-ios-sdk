import Foundation

/// A widget-to-host message (contracts/bridge-v1.md "Messages"), parsed defensively: unknown
/// types, malformed JSON and missing fields give `nil`; heights are clamped to 0…10,000.
enum BridgeMessage: Equatable {
    case ready(height: CGFloat, bridge: Int?)
    case resize(height: CGFloat, loading: Bool)
    case expand(height: CGFloat)
    case collapse(height: CGFloat)
    case click(eventId: String)
    case empty(reason: String)
    case dismiss
}

/// The outcome of reading one message from the bridge.
enum ParsedMessage: Equatable {
    /// A message this SDK acts on.
    case message(BridgeMessage)
    /// `groovy:ready` naming another protocol version: stop with `empty(unsupported)` (rule 5).
    case unsupportedBridge(Int)
    /// Dropped: another version's envelope, an unknown type, or malformed. The reason is a short
    /// word for the debug log (never the payload).
    case dropped(String)
}

enum BridgeMessageParser {
    static let maxHeight: CGFloat = 10_000

    /// Parse the JSON string the injected script forwards. `groovy:ready` is read first, before
    /// the version filter; every other message stamped with a `bridge` other than
    /// `bridgeVersion` is dropped (an unstamped one is accepted, as a pre-stamping widget sends).
    static func parse(_ json: String) -> ParsedMessage {
        guard json.utf8.count <= 64 * 1024,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              let type = envelope["type"] as? String else {
            return .dropped("malformed")
        }
        let payload = envelope["payload"] as? [String: Any]
        let stamped = integer(envelope["bridge"])

        // Rule 5: ready first, before the version filter.
        if type == "groovy:ready" {
            let announced = integer(payload?["bridge"]) ?? stamped
            if let announced, announced != bridgeVersion { return .unsupportedBridge(announced) }
            return .message(.ready(height: clamp(number(payload?["height"]) ?? 0), bridge: announced))
        }
        if let stamped, stamped != bridgeVersion { return .dropped("bridge \(stamped)") }

        switch type {
        case "groovy:resize":
            guard let height = number(payload?["height"]) else { return .dropped("resize without height") }
            return .message(.resize(height: clamp(height), loading: (payload?["loading"] as? Bool) == true))
        case "groovy:expand", "groovy:collapse":
            guard let height = number(payload?["height"]) else { return .dropped("\(type) without height") }
            return .message(type == "groovy:expand" ? .expand(height: clamp(height)) : .collapse(height: clamp(height)))
        case "groovy:click":
            guard let eventId = payload?["eventId"] as? String, !eventId.isEmpty, eventId.count <= 128 else {
                return .dropped("click without event id")
            }
            return .message(.click(eventId: eventId))
        case "groovy:empty":
            guard let reason = payload?["reason"] as? String else { return .dropped("empty without reason") }
            return .message(.empty(reason: reason))
        case "groovy:dismiss":
            return .message(.dismiss)
        default:
            return .dropped("unknown type")
        }
    }

    /// Clamp to 0…`maxHeight`; NaN or infinite → 0.
    static func clamp(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), Double(maxHeight)))
    }

    /// A JSON number (never a boolean, which `NSNumber` would also bridge).
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let double = number(value), double.rounded() == double, abs(double) < 1_000_000 else { return nil }
        return Int(double)
    }
}
