import SwiftUI

/// The Groovy widget in SwiftUI: a `GroovyWidgetView` sized by the widget's height.
public struct GroovyWidget: View {
    private let configuration: WidgetConfiguration
    private let initialHeight: CGFloat
    private let context: GroovyContext
    private let onEvent: ((GroovyWidgetEvent) -> Void)?

    public init(publisherId: String, accountId: String, placement: String? = nil,
                widgetVariant: String? = nil, experiment: GroovyExperiment? = nil,
                initialHeight: CGFloat = 0,
                context: GroovyContext = GroovyContext(),
                onEvent: ((GroovyWidgetEvent) -> Void)? = nil) {
        self.configuration = WidgetConfiguration(publisherId: publisherId, accountId: accountId,
                                                 placement: placement, widgetVariant: widgetVariant,
                                                 experiment: experiment, environment: Settings.shared.environment)
        self.initialHeight = initialHeight
        self.context = context
        self.onEvent = onEvent
    }

    public var body: some View {
        Representable(configuration: configuration, initialHeight: initialHeight, context: context, onEvent: onEvent)
    }
}

/// iOS 16+: `sizeThatFits` gives SwiftUI the widget's height for the proposed width. iOS 15:
/// SwiftUI reads the view's intrinsic content size, which the view keeps up to date.
private struct Representable: UIViewRepresentable {
    let configuration: WidgetConfiguration
    let initialHeight: CGFloat
    let context: GroovyContext
    let onEvent: ((GroovyWidgetEvent) -> Void)?

    func makeUIView(context _: Context) -> GroovyWidgetView {
        let view = GroovyWidgetView(publisherId: configuration.publisherId, accountId: configuration.accountId,
                                    placement: configuration.placement, widgetVariant: configuration.widgetVariant,
                                    experiment: configuration.experiment, initialHeight: initialHeight,
                                    context: context)
        view.update(configuration: configuration, initialHeight: initialHeight, context: context)
        view.onEvent = onEvent
        return view
    }

    func updateUIView(_ view: GroovyWidgetView, context _: Context) {
        view.onEvent = onEvent
        view.update(configuration: configuration, initialHeight: initialHeight, context: context)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GroovyWidgetView, context _: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        return CGSize(width: width, height: uiView.intrinsicContentSize.height)
    }

    static func dismantleUIView(_ view: GroovyWidgetView, coordinator _: ()) {
        // Now, not at deinit: SwiftUI may keep the view alive briefly (research R17).
        view.destroy()
    }
}
