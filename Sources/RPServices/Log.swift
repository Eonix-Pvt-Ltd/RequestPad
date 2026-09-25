import OSLog
import RPCore

/// Loggers for every subsystem area. All dynamic values must be logged with `privacy: .private` (the default for
/// strings) or explicitly redacted; secrets, headers, bodies and file contents are never logged (B1).
public enum Log {
    public enum Category: String, CaseIterable, Sendable {
        case app
        case network
        case storage
        case collections
        case oauth
        case echo
        case store
        case diagnostics
    }

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: AppConstants.loggingSubsystem, category: category.rawValue)
    }

    /// Reduces a URL to scheme and host (plus port) for logs and diagnostics, dropping path, query, fragment and
    /// credentials, which can carry identifiers or tokens (X04.3).
    public static func redacted(_ url: URL) -> String {
        guard let rawScheme = url.scheme, let rawHost = url.host(percentEncoded: false), !rawHost.isEmpty else {
            return "<redacted-url>"
        }
        let scheme = rawScheme.lowercased()
        // IPv6 literals need brackets to stay unambiguous next to a port.
        let host = rawHost.contains(":") ? "[\(rawHost.lowercased())]" : rawHost.lowercased()
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}
