import Foundation

/// SDK-wide settings (specs/222-mobile-sdk/contracts/sdk-public-api.md).
public enum Groovy {
    /// How much the SDK writes to the system log. `.none` by default.
    public static var logLevel: GroovyLogLevel {
        get { Settings.shared.logLevel }
        set { Settings.shared.logLevel = newValue }
    }

    /// The SDK's version, recorded on Groovy's events (one number for iOS and Android per release).
    public static let version = "1.0.1"

    /// Internal: which Groovy environment the widget is loaded from. `.production` by default.
    /// Not part of the documented interface; any other value logs a warning on every load.
    @_spi(GroovyInternal) public static var environment: GroovyEnvironment {
        get { Settings.shared.environment }
        set { Settings.shared.environment = newValue }
    }
}

/// How much the SDK logs. Lines start `[Groovy]` and go to `os.Logger`
/// (subsystem `com.joingroovy.sdk`). Payloads, the context and click URLs are never logged.
public enum GroovyLogLevel: Int, Comparable {
    case none = 0, info, debug

    public static func < (lhs: GroovyLogLevel, rhs: GroovyLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Internal: the Groovy environment the widget is loaded from. Its hosts are frozen in bridge v1.
@_spi(GroovyInternal) public enum GroovyEnvironment: String {
    case production, staging, dev
}

/// Process-wide settings. The environment is read when a view is created (a view keeps it).
final class Settings {
    static let shared = Settings()
    private let lock = NSLock()
    private var _logLevel: GroovyLogLevel = .none
    private var _environment: GroovyEnvironment = .production

    var logLevel: GroovyLogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _logLevel }
        set { lock.lock(); _logLevel = newValue; lock.unlock() }
    }

    var environment: GroovyEnvironment {
        get { lock.lock(); defer { lock.unlock() }; return _environment }
        set { lock.lock(); _environment = newValue; lock.unlock() }
    }
}
