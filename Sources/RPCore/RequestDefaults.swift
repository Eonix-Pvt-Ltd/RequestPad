import Foundation

/// Default limits applied to every request and response. Values come from the PRD (F01.6, F02.7) and B8.
public enum RequestDefaults {
    /// Default request timeout (B8: 30 s on all network calls).
    public static let timeout: Duration = .seconds(30)
    /// Allowed per-request timeout range (F01.6).
    public static let timeoutRange: ClosedRange<Duration> = .seconds(1)...Duration.seconds(600)
    /// Maximum redirects followed before failing (F01.6).
    public static let maximumRedirects = 10
    /// Bodies above this size are streamed to a file and not rendered (F02.7, A9).
    public static let maximumRenderedBodyBytes = 10 * 1024 * 1024

    /// Clamps a user-entered timeout into ``timeoutRange``.
    public static func clampedTimeout(_ value: Duration) -> Duration {
        min(max(value, timeoutRange.lowerBound), timeoutRange.upperBound)
    }
}
