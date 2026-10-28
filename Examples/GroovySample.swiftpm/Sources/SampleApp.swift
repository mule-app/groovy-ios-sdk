import SwiftUI
@_spi(GroovyInternal) import GroovySDK

/// The sample app. The launch argument `-GroovyEnvironment dev|staging` selects an internal
/// environment (only this app reads it; the SDK warns on every load when it is not production).
@main
struct SampleApp: App {
    @StateObject private var settings = SampleSettings()
    // `-SampleTab swiftui|uikit|two|storage|settings` opens on that tab, for scripted runs.
    @State private var tab = UserDefaults.standard.string(forKey: "SampleTab") ?? "swiftui"

    init() {
        switch UserDefaults.standard.string(forKey: "GroovyEnvironment") {
        case "dev": Groovy.environment = .dev
        case "staging": Groovy.environment = .staging
        default: Groovy.environment = .production
        }
        Groovy.logLevel = .debug
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                SwiftUIScreen().tabItem { Label("SwiftUI", systemImage: "swift") }.tag("swiftui")
                UIKitScreen().tabItem { Label("UIKit", systemImage: "square.stack") }.tag("uikit")
                TwoWidgetsScreen().tabItem { Label("Two", systemImage: "square.split.1x2") }.tag("two")
                StorageScreen().tabItem { Label("Storage", systemImage: "internaldrive") }.tag("storage")
                SettingsScreen().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag("settings")
            }
            .environmentObject(settings)
        }
    }
}

/// What the screens load, edited on the Settings tab. Launch arguments preset it for scripted runs:
/// `-SamplePublisher`, `-SampleAccount`, `-SamplePlacement`, `-SampleVariant`, `-SampleInitialHeight`,
/// `-SampleRetailer`, `-SampleParcelStatus`; `-SampleUserIdKey 1` adds a `user_id` custom key to the
/// context (spec 230 quickstart case 10: the SDK drops it with a debug line).
final class SampleSettings: ObservableObject {
    @Published var publisherId: String
    @Published var accountId: String
    @Published var placement: String
    @Published var widgetVariant: String
    @Published var experimentId = ""
    @Published var experimentVariant = ""
    @Published var initialHeight: Double
    @Published var retailer: String
    @Published var parcelStatus: String
    @Published var userIdKey: Bool
    @Published var log: [String] = []

    init() {
        let defaults = UserDefaults.standard
        publisherId = defaults.string(forKey: "SamplePublisher") ?? "test-publisher"
        accountId = defaults.string(forKey: "SampleAccount") ?? "GR-TEST01"
        placement = defaults.string(forKey: "SamplePlacement") ?? "tracking.top"
        widgetVariant = defaults.string(forKey: "SampleVariant") ?? ""
        initialHeight = defaults.double(forKey: "SampleInitialHeight")
        retailer = defaults.string(forKey: "SampleRetailer") ?? "asos"
        parcelStatus = defaults.string(forKey: "SampleParcelStatus") ?? "out_for_delivery"
        userIdKey = defaults.bool(forKey: "SampleUserIdKey")
    }

    var experiment: GroovyExperiment? {
        experimentId.isEmpty && experimentVariant.isEmpty ? nil : GroovyExperiment(id: experimentId, variant: experimentVariant)
    }

    var context: GroovyContext {
        GroovyContext(retailer: retailer, parcelStatus: parcelStatus, country: "GB",
                      custom: userIdKey ? ["user_id": .string("u-sentinel-230")] : [:])
    }

    func record(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.insert("\(stamp) \(line)", at: 0)
        print("[Sample] \(line)")
    }
}

func describe(_ event: GroovyWidgetEvent) -> String {
    switch event {
    case .loaded(let height): return "loaded \(Int(height))"
    case .resized(let height): return "resized \(Int(height))"
    case .offerOpened(let eventId): return "offerOpened \(eventId.isEmpty ? "(no id)" : "id")"
    case .dismissed: return "dismissed"
    case .empty(let reason): return "empty \(reason.rawValue)"
    }
}
