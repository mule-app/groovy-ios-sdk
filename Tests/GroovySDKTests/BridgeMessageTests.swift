import XCTest
@_spi(GroovyInternal) @testable import GroovySDK

/// T027: the message parser (contracts/bridge-v1.md "Messages", "Protocol versions" rule 5).
final class BridgeMessageTests: XCTestCase {
    func testParsesEveryBridgeV1Type() throws {
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:ready","payload":{"version":"1.0.0","height":120,"bridge":1},"bridge":1}"#),
                       .message(.ready(height: 120, bridge: 1)))
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:resize","payload":{"height":250.5},"bridge":1}"#),
                       .message(.resize(height: 250.5, loading: false)))
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:expand","payload":{"expanded":true,"height":300},"bridge":1}"#),
                       .message(.expand(height: 300)))
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:collapse","payload":{"expanded":false,"height":56},"bridge":1}"#),
                       .message(.collapse(height: 56)))
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:click","payload":{"eventId":"e-1","pageRef":"p"},"bridge":1}"#),
                       .message(.click(eventId: "e-1")))
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:empty","payload":{"reason":"no_fill"},"bridge":1}"#),
                       .message(.empty(reason: "no_fill")))
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:dismiss","payload":{},"bridge":1}"#),
                       .message(.dismiss))
    }

    func testReadsTheLoadingFlag() throws {
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:resize","payload":{"height":907,"loading":true},"bridge":1}"#),
                       .message(.resize(height: 907, loading: true)))
        // Only `true` marks a loading height.
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:resize","payload":{"height":90,"loading":"yes"},"bridge":1}"#),
                       .message(.resize(height: 90, loading: false)))
    }

    func testDropsMalformedJSONAndUnknownTypes() throws {
        for json in ["", "not json", "[]", "null", #"{"payload":{}}"#, #"{"type":"other:resize","payload":{"height":1}}"#,
                     #"{"type":"groovy:new-thing","payload":{}}"#, #"{"type":"groovy:resize","payload":{}}"#,
                     #"{"type":"groovy:resize","payload":{"height":"tall"}}"#, #"{"type":"groovy:click","payload":{}}"#,
                     #"{"type":"groovy:empty","payload":{"reason":5}}"#, #"{"type":"groovy:resize"}"#] {
            guard case .dropped = BridgeMessageParser.parse(json) else {
                return XCTFail("not dropped: \(json)")
            }
        }
    }

    func testClampsHeights() throws {
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:resize","payload":{"height":99999},"bridge":1}"#),
                       .message(.resize(height: 10_000, loading: false)))
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:resize","payload":{"height":-5},"bridge":1}"#),
                       .message(.resize(height: 0, loading: false)))
        XCTAssertEqual(BridgeMessageParser.clamp(.nan), 0)
        XCTAssertEqual(BridgeMessageParser.clamp(.infinity), 0)
    }

    func testDropsAMessageStampedWithAnotherVersion() throws {
        guard case .dropped = BridgeMessageParser.parse(#"{"type":"groovy:resize","payload":{"height":100},"bridge":2}"#) else {
            return XCTFail("a version-2 message must be dropped")
        }
    }

    func testAcceptsAnUnstampedMessage() throws {
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:resize","payload":{"height":100}}"#),
                       .message(.resize(height: 100, loading: false)))
    }

    func testReadsReadyBeforeTheVersionFilter() throws {
        // A ready stamped 2 is not silently dropped: the SDK must learn the mismatch (rule 5).
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:ready","payload":{"height":0,"bridge":2},"bridge":2}"#),
                       .unsupportedBridge(2))
    }

    func testReportsAReadyNamingAnotherVersionAsUnsupported() throws {
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:ready","payload":{"height":0,"bridge":3}}"#),
                       .unsupportedBridge(3))
        // A ready with no bridge (a pre-stamping widget) is accepted.
        XCTAssertEqual(BridgeMessageParser.parse(#"{"type":"groovy:ready","payload":{"version":"1.0.0","height":10}}"#),
                       .message(.ready(height: 10, bridge: nil)))
    }
}
