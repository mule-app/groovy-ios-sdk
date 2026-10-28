import Combine
import SwiftUI
import UIKit
import WebKit
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
    private let logLabel = UILabel()
    private var loadedWith: String?
    private var subscriptions = Set<AnyCancellable>()

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
        // The latest log lines, for scripted runs that read the screen.
        logLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        logLabel.numberOfLines = 0
        logLabel.accessibilityIdentifier = "sample-log"
        logLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logLabel)
        NSLayoutConstraint.activate([
            logLabel.topAnchor.constraint(equalTo: below.bottomAnchor, constant: 8),
            logLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        settings.$log.receive(on: DispatchQueue.main)
            .sink { [weak self] lines in self?.logLabel.text = lines.prefix(24).joined(separator: "\n") }
            .store(in: &subscriptions)
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

    /// Scripted runs: `-SampleSteps "8:tap,9:cta,14:close,16:decline,22:context"` (seconds after the
    /// widget is created): record a native tap (as a finger would), click the offer button from
    /// script (alone, since 1.0.1, it opens nothing: the refusal demonstration), close the sheet,
    /// tap "No thanks", change the context.
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
        case "tap":
            #if DEBUG
            widget?.simulateTap()
            #endif
        case "cta":
            widget?.evaluateInWidget("document.querySelector('.promo-banner__cta').click(); true")
        case "samehost":
            // Spec 230 quickstart case 2 (PR 976): the page navigates its own frame to the widget
            // address without `sdk_platform`; the SDK refuses it, so the page keeps its address.
            widget?.evaluateInWidget("var u = new URL(location.href); u.searchParams.delete('sdk_platform'); location.href = u.toString(); true")
        case "otheracct":
            widget?.evaluateInWidget("var u = new URL(location.href); u.searchParams.set('account_id', 'GR-OTHER'); location.href = u.toString(); true")
        case "address":
            widget?.evaluateInWidget("location.pathname + location.search") { [weak self] result in
                self?.settings.record("UIKit: widget address \((try? result.get()) as? String ?? "error")")
            }
        case "script":
            // Spec 230 quickstart case 6 (PR 976): a script from a host the response header allows
            // but the SDK-mode document policy does not; the browser must refuse it before a tap.
            widget?.evaluateInWidget(Self.scriptProbe)
        case "scriptread":
            widget?.evaluateInWidget(Self.scriptReadProbe) { [weak self] result in
                self?.settings.record("UIKit: script probe \((try? result.get()) as? String ?? "error")")
            }
        case "decline":
            widget?.evaluateInWidget("document.querySelector('.promo-banner__dismiss, .promo-banner__restart').click(); true")
        case "close":
            presentedViewController?.dismiss(animated: false)
            view.window?.rootViewController?.presentedViewController?.dismiss(animated: false)
        case "context":
            settings.parcelStatus = settings.parcelStatus == "delivered" ? "out_for_delivery" : "delivered"
            widget?.context = settings.context
        case "probe":
            // Spec 230 quickstart case 14: what the widget's page can read of this origin's storage.
            widget?.evaluateInWidget("(localStorage.getItem('probe') || 'none') + '|' + (document.cookie || 'none')") { [weak self] result in
                self?.settings.record("UIKit: widget storage probe \((try? result.get()) as? String ?? "error")")
            }
        case "hosts":
            // Spec 230 quickstart cases 6, 11 and 14: the hosts the widget's page has contacted, with counts.
            widget?.evaluateInWidget(Self.hostsScript) { [weak self] result in
                self?.settings.record("UIKit: widget hosts \((try? result.get()) as? String ?? "error")")
            }
        case "perm":
            // Spec 230 quickstart case 16: the page asks for the camera, the microphone and the location.
            widget?.evaluateInWidget(Self.permissionsScript) { [weak self] result in
                self?.settings.record("UIKit: permissions asked \((try? result.get()) as? Bool ?? false)")
            }
        case "permread":
            widget?.evaluateInWidget("JSON.stringify(window.__perm || {})") { [weak self] result in
                self?.settings.record("UIKit: permissions \((try? result.get()) as? String ?? "error")")
            }
        case "version":
            settings.record("UIKit: SDK version \(Groovy.version)")
        default:
            break
        }
    }

    private static let scriptProbe = """
    (function () { window.__script = { state: 'pending' };
      var s = document.createElement('script'); s.src = 'https://static.cloudflareinsights.com/beacon.min.js';
      s.onload = function () { window.__script.state = 'loaded'; };
      s.onerror = function () { window.__script.state = 'refused'; };
      document.addEventListener('securitypolicyviolation', function (e) {
        window.__script.violation = e.violatedDirective + ' ' + e.blockedURI; });
      document.head.appendChild(s); return true; })()
    """

    private static let scriptReadProbe = """
    (function () { var m = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
      var d = m ? m.content.split(';').map(function (p) { return p.trim(); }).filter(function (p) { return p.indexOf('script-src') === 0; }) : [];
      var entries = performance.getEntriesByType('resource').filter(function (e) { return e.name.indexOf('cloudflareinsights') >= 0; })
        .map(function (e) { return { transferSize: e.transferSize, encodedBodySize: e.encodedBodySize, responseStatus: e.responseStatus, duration: Math.round(e.duration), protocol: e.nextHopProtocol }; });
      return JSON.stringify({ probe: window.__script || null, scriptSrc: d[0] || null, entries: entries }); })()
    """

    private static let hostsScript = """
    (function () { var c = {}; performance.getEntriesByType('resource').forEach(function (e) {
      var h; try { h = new URL(e.name).host; } catch (_) { h = e.name.slice(0, 24); } c[h] = (c[h] || 0) + 1; });
      return JSON.stringify(c); })()
    """

    private static let permissionsScript = """
    (function () { window.__perm = {};
      var m = navigator.mediaDevices;
      if (m && m.getUserMedia) { m.getUserMedia({ video: true, audio: true }).then(function () { window.__perm.media = 'granted'; },
        function (e) { window.__perm.media = 'rejected ' + e.name; }); } else { window.__perm.media = 'absent'; }
      if (navigator.geolocation) { navigator.geolocation.getCurrentPosition(function () { window.__perm.geo = 'granted'; },
        function (e) { window.__perm.geo = 'rejected ' + e.code; }); } else { window.__perm.geo = 'absent'; }
      return true; })()
    """

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

/// Spec 230 quickstart case 14: the app's own web content on the widget's origin, in the app's
/// default web storage, beside the widget. The app page writes `probe` in `localStorage` and a
/// cookie; the widget's page (the SDK's own storage) must read none of it, and the reverse.
struct StorageScreen: View {
    @EnvironmentObject private var settings: SampleSettings
    @State private var appProbe = "(not read yet)"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("The app's own web view (default storage, the widget's origin)").font(.footnote).padding(.horizontal)
                AppWebView(publisherId: settings.publisherId, probe: $appProbe).frame(height: 120)
                Text("App page reads: \(appProbe)").font(.caption.monospaced()).padding(.horizontal)
                Text("The widget (its own storage)").font(.footnote).padding(.horizontal)
                GroovyWidget(publisherId: settings.publisherId, accountId: settings.accountId,
                             placement: settings.placement.isEmpty ? nil : settings.placement,
                             context: settings.context) { settings.record("Storage: \(describe($0))") }
                LogView()
            }
        }
    }
}

/// A plain WKWebView on the app's default data store, loading the widget's origin, that writes
/// `probe` to localStorage and a cookie, then reads both back.
struct AppWebView: UIViewRepresentable {
    let publisherId: String
    @Binding var probe: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        let environment: String
        switch Groovy.environment {
        case .dev: environment = "widget-embed-dev.joingroovy.com"
        case .staging: environment = "widget-embed-staging.joingroovy.com"
        case .production: environment = "widget-embed.joingroovy.com"
        }
        if let url = URL(string: "https://\(environment)/v1/\(publisherId)/frame.html?account_id=none") {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(probe: $probe) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var probe: String
        init(probe: Binding<String>) { _probe = probe }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("""
            localStorage.setItem('probe', 'app'); document.cookie = 'probe=app; path=/';
            (localStorage.getItem('probe') || 'none') + '|' + (document.cookie || 'none')
            """) { [weak self] result, _ in
                self?.probe = (result as? String) ?? "error"
                print("[Sample] Storage: app page reads \((result as? String) ?? "error")")
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
