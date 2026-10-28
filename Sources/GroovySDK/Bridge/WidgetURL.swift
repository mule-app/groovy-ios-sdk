import Foundation

/// The hosts of an environment, frozen in bridge v1 (contracts/bridge-v1.md "Part of bridge v1
/// beyond the messages"): released SDKs load the widget only from `widgetHost` and open offers
/// only on `https://<clickHost>/trk/c`.
struct EnvironmentHosts: Equatable {
    let widgetHost: String
    let clickHost: String

    static func of(_ environment: GroovyEnvironment) -> EnvironmentHosts {
        switch environment {
        case .production: return EnvironmentHosts(widgetHost: "widget-embed.joingroovy.com", clickHost: "api.joingroovy.com")
        case .staging: return EnvironmentHosts(widgetHost: "widget-embed-staging.joingroovy.com", clickHost: "api-stage.joingroovy.com")
        case .dev: return EnvironmentHosts(widgetHost: "widget-embed-dev.joingroovy.com", clickHost: "api-dev.joingroovy.com")
        }
    }
}

/// What a load is built from. A change to any field reloads the page (research R17).
struct WidgetConfiguration: Equatable {
    var publisherId: String
    var accountId: String
    var placement: String?
    var widgetVariant: String?
    var experiment: GroovyExperiment?
    var environment: GroovyEnvironment
}

/// The protocol version this SDK speaks (contracts/bridge-v1.md "Protocol versions").
let bridgeVersion = 1

/// Spec 230 (the CTO's decision on PR 976) — what tells the widget document the SDK loaded apart
/// from any other page of the widget host: the platform the address builder sets, the account ID
/// it sends and the path it builds. Read by the navigation rule (`NavigationPolicy.isWidgetDocument`),
/// so the main frame can never hold the hosted page outside SDK mode (data-model "Navigation rule").
struct SdkMarker: Equatable {
    let platform: String
    let accountId: String
    let path: String
}

enum WidgetURL {
    /// The platform this SDK announces in `sdk_platform`.
    static let platform = "ios"

    /// The marker of a configured load, from the same values `build` puts in the address.
    static func marker(for configuration: WidgetConfiguration) -> SdkMarker {
        let publisher = configuration.publisherId.trimmingCharacters(in: .whitespacesAndNewlines)
        return SdkMarker(platform: platform,
                         accountId: configuration.accountId.trimmingCharacters(in: .whitespacesAndNewlines),
                         path: "/v1/\(publisher)/frame.html")
    }

    /// `https://<widget host>/v1/<publisherId>/frame.html?account_id&placement&widget_variant&
    /// experiment_id&variant&sdk_platform=ios&sdk_version&bridge=1` (data-model "Address parameters
    /// the SDK sets"). Never `publisher`, `country`, `region`, `ad_id`, `algorithm_name`,
    /// `dev_mode`, `retailer` or the initial height. Nil when the publisher ID cannot form a path.
    static func build(_ configuration: WidgetConfiguration) -> URL? {
        let publisher = configuration.publisherId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPathSegment(publisher) else { return nil }

        var items = [URLQueryItem(name: "account_id", value: configuration.accountId.trimmingCharacters(in: .whitespacesAndNewlines))]
        if let placement = configuration.placement?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if isValidPlacement(placement) {
                items.append(URLQueryItem(name: "placement", value: placement))
            } else {
                Log.debug("placement is not a valid label (letters, digits, '.', '_', '-', up to 64): not sent")
            }
        }
        if let variant = nonEmpty(configuration.widgetVariant) {
            items.append(URLQueryItem(name: "widget_variant", value: variant))
        }
        if let id = nonEmpty(configuration.experiment?.id) {
            items.append(URLQueryItem(name: "experiment_id", value: id))
        }
        if let variant = nonEmpty(configuration.experiment?.variant) {
            items.append(URLQueryItem(name: "variant", value: variant))
        }
        items += [
            URLQueryItem(name: "sdk_platform", value: platform),
            URLQueryItem(name: "sdk_version", value: Groovy.version),
            URLQueryItem(name: "bridge", value: String(bridgeVersion)),
        ]

        var components = URLComponents()
        components.scheme = "https"
        components.host = EnvironmentHosts.of(configuration.environment).widgetHost
        components.path = "/v1/\(publisher)/frame.html"
        components.queryItems = items
        // `URLComponents` leaves `&`, `=` and `+` unescaped in values: escape them, so a value can
        // never add a parameter.
        components.percentEncodedQuery = items.map { item in
            "\(item.name)=\(escape(item.value ?? ""))"
        }.joined(separator: "&")
        return components.url
    }

    /// The placement rule shared with the widget and services (`modules/shared/model/placement`).
    static func isValidPlacement(_ placement: String) -> Bool {
        (1...64).contains(placement.count) && placement.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "." || char == "_" || char == "-")
        }
    }

    private static func isValidPathSegment(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.count <= 128 && value.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "." || char == "_" || char == "-")
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }
}
