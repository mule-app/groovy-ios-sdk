import Foundation

/// What the app knows about the parcel, sent to the widget as `groovy:context` (data-model
/// "Context"). The SDK does not validate values; Groovy's ad router does. Since 1.0.1 it carries no
/// user ID: the SDK sends no customer identifier of any kind (spec 230 FR-006), and a custom key
/// spelled as one is never sent.
public struct GroovyContext: Equatable {
    public var retailer: String?
    public var parcelStatus: String?
    public var country: String?
    /// Fields agreed at onboarding.
    public var custom: [String: GroovyContextValue]

    public init(retailer: String? = nil, parcelStatus: String? = nil, country: String? = nil,
                custom: [String: GroovyContextValue] = [:]) {
        self.retailer = retailer
        self.parcelStatus = parcelStatus
        self.country = country
        self.custom = custom
    }
}

/// A custom context value: a string, a number or a boolean.
public enum GroovyContextValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

/// The publisher's own test labels, recorded on Groovy's events (`experiment_id`, `variant`).
public struct GroovyExperiment: Equatable {
    public var id: String?
    public var variant: String?

    public init(id: String? = nil, variant: String? = nil) {
        self.id = id
        self.variant = variant
    }
}

/// Why the widget shows nothing (its height is 0).
public enum GroovyEmptyReason: String {
    /// No offer for this context.
    case noFill = "no_fill"
    /// The account ID does not belong to this publisher ID.
    case accountRejected = "account_rejected"
    /// The widget hit an error.
    case error
    /// The widget page did not load (offline, for instance).
    case loadFailed = "load_failed"
    /// The widget did not start, or did not answer a context, within 10 seconds.
    case timeout
    /// The widget speaks a bridge version this SDK does not.
    case unsupported
}

/// What the view reports, in both styles.
public enum GroovyWidgetEvent: Equatable {
    /// First content of a load, at this height (points).
    case loaded(CGFloat)
    /// The content's height changed.
    case resized(CGFloat)
    /// The visitor opened an offer: the `eventId` of its `groovy:click` (never the URL).
    case offerOpened(eventId: String)
    /// The visitor declined an offer; the widget shows its next one.
    case dismissed
    /// The widget shows nothing.
    case empty(GroovyEmptyReason)
}
