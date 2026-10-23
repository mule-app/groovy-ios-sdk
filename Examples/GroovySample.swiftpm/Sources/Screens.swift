import SwiftUI
import UIKit
@_spi(GroovyInternal) import GroovySDK

/// The SwiftUI style: one widget with a label right below it (quickstart case 25 watches the label).
struct SwiftUIScreen: View {
    @EnvironmentObject private var settings: SampleSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your parcel is out for delivery").font(.headline).padding()
                GroovyWidget(publisherId: settings.publisherId, accountId: settings.accountId,
                             placement: settings.placement.isEmpty ? nil : settings.placement,
                             widgetVariant: settings.widgetVariant.isEmpty ? nil : settings.widgetVariant,
                             experiment: settings.experiment, initialHeight: CGFloat(settings.initialHeight),
                             context: settings.context) { event in
                    settings.record("SwiftUI: \(describe(event))")
                }
                Text("Below the widget").font(.footnote).foregroundColor(.secondary).padding()
                    .accessibilityIdentifier("below-swiftui")
                LogView()
            }
        }
    }
}

/// The UIKit style, in a plain view controller with Auto Layout.
struct UIKitScreen: UIViewControllerRepresentable {
    @EnvironmentObject private var settings: SampleSettings

    func makeUIViewController(context: Context) -> SampleViewController {
        SampleViewController(settings: settings)
    }

    func updateUIViewController(_ controller: SampleViewController, context: Context) {
        controller.apply(settings)
    }
}

final class SampleViewController: UIViewController, GroovyWidgetListener {
    private let settings: SampleSettings
    private var widget: GroovyWidgetView?
    private let below = UILabel()
    private var loadedWith: String?

    init(settings: SampleSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        below.text = "Below the widget"
        below.font = .preferredFont(forTextStyle: .footnote)
        below.textColor = .secondaryLabel
        below.accessibilityIdentifier = "below-uikit"
        below.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(below)
        apply(settings)
    }

    /// Rebuilds the widget when the IDs change; otherwise updates the context (FR-009).
    func apply(_ settings: SampleSettings) {
        guard isViewLoaded else { return }
        let key = "\(settings.publisherId)|\(settings.accountId)|\(settings.placement)|\(settings.widgetVariant)|\(settings.initialHeight)|\(settings.experimentId)|\(settings.experimentVariant)"
        if key == loadedWith, let widget {
            // Setting the context always resends it: only when it changed (not on every log line).
            if widget.context != settings.context { widget.context = settings.context }
            return
        }
        loadedWith = key
        widget?.removeFromSuperview()
        let widget = GroovyWidgetView(publisherId: settings.publisherId, accountId: settings.accountId,
                                      placement: settings.placement.isEmpty ? nil : settings.placement,
                                      widgetVariant: settings.widgetVariant.isEmpty ? nil : settings.widgetVariant,
                                      experiment: settings.experiment, initialHeight: CGFloat(settings.initialHeight),
                                      context: settings.context)
        widget.listener = self
        widget.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(widget)
        NSLayoutConstraint.activate([
            widget.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            widget.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            widget.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            below.topAnchor.constraint(equalTo: widget.bottomAnchor, constant: 8),
            below.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])
        self.widget = widget
        scheduleSteps()
    }

    /// Scripted runs: `-SampleSteps "8:cta,14:close,16:decline,22:context"` (seconds after the widget
    /// is created): tap the offer button, close the sheet, tap "No thanks", change the context.
    private func scheduleSteps() {
        guard let steps = UserDefaults.standard.string(forKey: "SampleSteps") else { return }
        for step in steps.split(separator: ",") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            let action = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.run(action) }
        }
    }

    private func run(_ action: String) {
        settings.record("step \(action)")
        switch action {
        case "cta":
            widget?.evaluateInWidget("document.querySelector('.promo-banner__cta').click(); true")
        case "decline":
            widget?.evaluateInWidget("document.querySelector('.promo-banner__dismiss, .promo-banner__restart').click(); true")
        case "close":
            presentedViewController?.dismiss(animated: false)
            view.window?.rootViewController?.presentedViewController?.dismiss(animated: false)
        case "context":
            settings.parcelStatus = settings.parcelStatus == "delivered" ? "out_for_delivery" : "delivered"
            widget?.context = settings.context
        default:
            break
        }
    }

    func groovyWidget(_ view: GroovyWidgetView, didLoadWithHeight height: CGFloat) { settings.record("UIKit: loaded \(Int(height))") }
    func groovyWidget(_ view: GroovyWidgetView, didResizeTo height: CGFloat) { settings.record("UIKit: resized \(Int(height))") }
    func groovyWidget(_ view: GroovyWidgetView, didOpenOfferWithEventId eventId: String) { settings.record("UIKit: offerOpened \(eventId.isEmpty ? "(no id)" : "with an event id")") }
    func groovyWidgetDidDismiss(_ view: GroovyWidgetView) { settings.record("UIKit: dismissed") }
    func groovyWidget(_ view: GroovyWidgetView, isEmpty reason: GroovyEmptyReason) { settings.record("UIKit: empty \(reason.rawValue)") }
}

/// Two widgets on one screen with different placements (quickstart case 20).
struct TwoWidgetsScreen: View {
    @EnvironmentObject private var settings: SampleSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                GroovyWidget(publisherId: settings.publisherId, accountId: settings.accountId, placement: "tracking.top",
                             context: settings.context) { settings.record("Top: \(describe($0))") }
                Text("Between the widgets").font(.footnote)
                GroovyWidget(publisherId: settings.publisherId, accountId: settings.accountId, placement: "tracking.bottom",
                             context: settings.context) { settings.record("Bottom: \(describe($0))") }
                Text("Below both").font(.footnote)
            }
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var settings: SampleSettings

    var body: some View {
        Form {
            Section("Widget") {
                TextField("Publisher ID", text: $settings.publisherId)
                TextField("Account ID", text: $settings.accountId)
                TextField("Placement", text: $settings.placement)
                TextField("Widget variant", text: $settings.widgetVariant)
                TextField("Experiment ID", text: $settings.experimentId)
                TextField("Experiment variant", text: $settings.experimentVariant)
                Stepper("Initial height: \(Int(settings.initialHeight)) pt", value: $settings.initialHeight, in: 0...600, step: 8)
            }
            Section("Context") {
                TextField("Retailer", text: $settings.retailer)
                TextField("Parcel status", text: $settings.parcelStatus)
                TextField("User ID (consented)", text: $settings.userId)
            }
            Section("Log") { LogView() }
        }
        .disableAutocorrection(true)
        .textInputAutocapitalization(.never)
    }
}

struct LogView: View {
    @EnvironmentObject private var settings: SampleSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(settings.log.prefix(20).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
        }
        .padding()
    }
}
