import Foundation

/// Identifiers and URLs shared by every module. Values come from `docs/DECISIONS.md` (human inputs, ADR-0002).
public enum AppConstants {
    /// The bundle identifier used on every platform (Universal Purchase).
    public static let bundleIdentifier = "lk.eonix.RequestPad"

    /// `os.Logger` subsystem. Equal to the bundle identifier (B1).
    public static let loggingSubsystem = bundleIdentifier

    /// `kSecAttrService` for every Keychain item the app writes (B5).
    public static let keychainService = bundleIdentifier

    /// Redirect URI registered with OAuth providers for the authorization-code flow (F05.4).
    public static let oauthRedirectURI = "requestpad://oauth/callback"

    /// Custom scheme passed to `ASWebAuthenticationSession` as the callback scheme.
    public static let oauthCallbackScheme = "requestpad"

    public static let supportEmail = "support@eonix.lk"

    // These literals are compile-time constants; `URL(string:)` cannot fail for them, which the tests assert.
    public static let privacyPolicyURL = staticURL("https://requestpad.eonix.lk/privacy")
    public static let termsOfUseURL = staticURL("https://requestpad.eonix.lk/terms")
    public static let supportURL = staticURL("https://requestpad.eonix.lk/support")
    /// Apple's standard EULA, linked from the paywall (B4.12).
    public static let appleStandardEULAURL = staticURL(
        "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    /// Subscription management page used on macOS (B4.8).
    public static let manageSubscriptionsURL = staticURL("https://apps.apple.com/account/subscriptions")

    /// Builds a `mailto:` URL for the support address with an optional subject.
    public static func supportMailURL(subject: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        if let subject, !subject.isEmpty {
            components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        }
        return components.url ?? staticURL("mailto:\(supportEmail)")
    }

    static func staticURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid static URL literal: \(string)")
        }
        return url
    }
}
