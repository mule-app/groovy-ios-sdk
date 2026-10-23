import XCTest
@_spi(GroovyInternal) @testable import GroovySDK

/// T027: the URL builder (data-model "Address parameters the SDK sets", contracts/bridge-v1.md).
final class WidgetURLTests: XCTestCase {
    private func configuration(_ change: (inout WidgetConfiguration) -> Void = { _ in }) -> WidgetConfiguration {
        var c = WidgetConfiguration(publisherId: "example-publisher", accountId: "GR-EXAMPLE", placement: nil,
                                    widgetVariant: nil, experiment: nil, environment: .production)
        change(&c)
        return c
    }

    private func query(_ url: URL?) -> [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testBuildsEveryParameter() throws {
        let url = WidgetURL.build(configuration {
            $0.placement = "tracking.top"
            $0.widgetVariant = "mini"
            $0.experiment = GroovyExperiment(id: "exp1", variant: "treatment")
        })
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "widget-embed.joingroovy.com")
        XCTAssertEqual(url?.path, "/v1/example-publisher/frame.html")
        XCTAssertEqual(query(url), [
            "account_id": "GR-EXAMPLE",
            "placement": "tracking.top",
            "widget_variant": "mini",
            "experiment_id": "exp1",
            "variant": "treatment",
            "sdk_platform": "ios",
            "sdk_version": Groovy.version,
            "bridge": "1",
        ])
    }

    func testDropsAnInvalidPlacement() throws {
        for bad in ["bad label", "", String(repeating: "a", count: 65), "a/b", "é"] {
            XCTAssertNil(query(WidgetURL.build(configuration { $0.placement = bad }))["placement"], bad)
        }
        XCTAssertEqual(query(WidgetURL.build(configuration { $0.placement = String(repeating: "a", count: 64) }))["placement"]?.count, 64)
        XCTAssertTrue(WidgetURL.isValidPlacement("A-z_0.9"))
    }

    func testOmitsEmptyOptionalParameters() throws {
        let q = query(WidgetURL.build(configuration {
            $0.widgetVariant = "  "
            $0.experiment = GroovyExperiment(id: "", variant: nil)
        }))
        XCTAssertNil(q["widget_variant"])
        XCTAssertNil(q["experiment_id"])
        XCTAssertNil(q["variant"])
    }

    func testNeverSendsForbiddenParametersOrTheInitialHeight() throws {
        let q = query(WidgetURL.build(configuration { $0.placement = "x" }))
        for forbidden in ["publisher", "country", "region", "ad_id", "algorithm_name", "dev_mode", "retailer",
                          "progress_ms", "initial_height", "height"] {
            XCTAssertNil(q[forbidden], forbidden)
        }
    }

    func testAnnouncesBridgeOne() throws {
        XCTAssertEqual(query(WidgetURL.build(configuration()))["bridge"], "1")
        XCTAssertEqual(bridgeVersion, 1)
    }

    func testUsesEachEnvironmentsWidgetHost() throws {
        XCTAssertEqual(WidgetURL.build(configuration { $0.environment = .staging })?.host, "widget-embed-staging.joingroovy.com")
        XCTAssertEqual(WidgetURL.build(configuration { $0.environment = .dev })?.host, "widget-embed-dev.joingroovy.com")
        XCTAssertEqual(EnvironmentHosts.of(.production).clickHost, "api.joingroovy.com")
        XCTAssertEqual(EnvironmentHosts.of(.staging).clickHost, "api-stage.joingroovy.com")
        XCTAssertEqual(EnvironmentHosts.of(.dev).clickHost, "api-dev.joingroovy.com")
    }

    func testRejectsAPublisherIdThatCannotFormAPath() throws {
        for bad in ["", " ", "a/b", "../x", "a b", "a?b"] {
            XCTAssertNil(WidgetURL.build(configuration { $0.publisherId = bad }), bad)
        }
    }

    func testPercentEncodesValues() throws {
        let url = WidgetURL.build(configuration {
            $0.accountId = "GR&X=1"
            $0.widgetVariant = "a b&c"
        })
        XCTAssertEqual(query(url)["account_id"], "GR&X=1")
        XCTAssertEqual(query(url)["widget_variant"], "a b&c")
        XCTAssertFalse(url!.absoluteString.contains("&X=1"))
    }
}
