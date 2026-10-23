import XCTest
@testable import GroovySDK

/// T053: one version for both platforms. `modules/mobile-sdk/VERSION` is the source; Swift cannot
/// read it at build time, so this test keeps `Groovy.version` equal to it (the Android build reads
/// the file directly). Skipped where the file is not next to the package (the public mirror).
final class VersionTests: XCTestCase {
    func testGroovyVersionIsTheVersionFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // GroovySDKTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // mobile-sdk
            .appendingPathComponent("VERSION")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("no modules/mobile-sdk/VERSION here")
        }
        XCTAssertEqual(Groovy.version, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
