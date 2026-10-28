import Foundation
import os

/// `[Groovy]` lines at `Groovy.logLevel` (research R19). Callers pass only what is safe: types,
/// heights, reasons, timings, host and path. Never a payload, the context, the query (it holds the
/// account ID) or a click URL.
enum Log {
    private static let logger = Logger(subsystem: "com.joingroovy.sdk", category: "widget")

    static func info(_ message: @autoclosure () -> String) {
        guard Groovy.logLevel >= .info else { return }
        let text = message()
        logger.info("[Groovy] \(text, privacy: .public)")
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard Groovy.logLevel >= .debug else { return }
        let text = message()
        logger.debug("[Groovy] \(text, privacy: .public)")
    }

    /// Always written, whatever the level: the internal environment is not production.
    static func warning(_ message: String) {
        logger.warning("[Groovy] \(message, privacy: .public)")
    }
}
