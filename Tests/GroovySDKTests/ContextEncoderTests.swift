import XCTest
@_spi(GroovyInternal) @testable import GroovySDK

/// T027: the groovy:context payload (data-model "Context").
final class ContextEncoderTests: XCTestCase {
    func testEncodesKnownAndCustomKeys() throws {
        let payload = ContextEncoder.payload(GroovyContext(
            retailer: "asos", parcelStatus: "out_for_delivery", country: "GB",
            custom: ["tier": .string("gold"), "count": .number(3), "member": .bool(true)]))
        XCTAssertEqual(payload["retailer"] as? String, "asos")
        XCTAssertEqual(payload["parcelStatus"] as? String, "out_for_delivery")
        XCTAssertEqual(payload["country"] as? String, "GB")
        XCTAssertEqual(payload["tier"] as? String, "gold")
        XCTAssertEqual(payload["count"] as? Double, 3)
        XCTAssertEqual(payload["member"] as? Bool, true)
        // Unset known keys are absent, not null.
        XCTAssertNil(ContextEncoder.payload(GroovyContext())["retailer"])
    }

    /// Spec 230 T016 (FR-006): no user ID leaves the SDK under any spelling, even as a custom key.
    func testNeverSendsAUserIdUnderAnySpelling() throws {
        let context = GroovyContext(retailer: "asos", custom: [
            "userId": .string("u-1"), "userID": .string("u-2"), "user_id": .string("u-3"), "userid": .string("u-4"),
            "tier": .string("gold"),
        ])
        let payload = ContextEncoder.payload(context)
        XCTAssertEqual(Set(payload.keys), ["retailer", "tier"])
        XCTAssertFalse(ContextEncoder.json(context).contains("u-"))
        XCTAssertEqual(ContextEncoder.userIdKeys, ["userId", "userID", "user_id", "userid"])
    }

    func testTheContextHasNoUserId() throws {
        // The interface: `GroovyContext` has no user ID (contracts/sdk-public-api.delta.md). A
        // reflection check, so a reintroduced field fails here before it reaches the guide.
        let labels = Mirror(reflecting: GroovyContext()).children.compactMap { $0.label }
        XCTAssertEqual(labels, ["retailer", "parcelStatus", "country", "custom"])
    }

    func testKnownKeysWinOverCustomKeys() throws {
        let payload = ContextEncoder.payload(GroovyContext(retailer: "asos", custom: ["retailer": .string("other")]))
        XCTAssertEqual(payload["retailer"] as? String, "asos")
    }

    func testDeliveryScriptPostsToTheWidgetOriginOnly() throws {
        let json = ContextEncoder.json(GroovyContext(retailer: "a\"b</script>"))
        let script = BridgeScript.deliverContext(json, widgetHost: "widget-embed-dev.joingroovy.com")
        XCTAssertTrue(script.contains("window.postMessage("))
        XCTAssertTrue(script.contains("\"https://widget-embed-dev.joingroovy.com\""))
        XCTAssertFalse(script.contains("location.origin"))
        XCTAssertTrue(script.contains("\"groovy:context\""))
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(object?["retailer"] as? String, "a\"b</script>")
    }

    func testDropsNonFiniteNumbers() throws {
        let context = GroovyContext(custom: ["a": .number(.nan), "b": .number(.infinity), "c": .number(1.5)])
        let payload = ContextEncoder.payload(context)
        XCTAssertNil(payload["a"])
        XCTAssertNil(payload["b"])
        XCTAssertEqual(payload["c"] as? Double, 1.5)
        XCTAssertEqual(ContextEncoder.json(context), #"{"c":1.5}"#)
    }
}
