import Foundation
import Testing

@testable import RPCore

@Suite("AppConstants")
struct AppConstantsTests {
    @Test func identifiersMatchBundleIdentifier() {
        #expect(AppConstants.bundleIdentifier == "lk.eonix.RequestPad")
        #expect(AppConstants.loggingSubsystem == AppConstants.bundleIdentifier)
        #expect(AppConstants.keychainService == AppConstants.bundleIdentifier)
    }

    @Test(arguments: [
        AppConstants.privacyPolicyURL, AppConstants.termsOfUseURL, AppConstants.supportURL,
    ])
    func legalURLsAreHTTPS(url: URL) {
        #expect(url.scheme == "https")
        #expect(url.host() != nil)
    }

    @Test func oauthRedirectUsesCallbackScheme() throws {
        let url = try #require(URL(string: AppConstants.oauthRedirectURI))
        #expect(url.scheme == AppConstants.oauthCallbackScheme)
    }

    @Test func supportMailURLWithoutSubject() {
        #expect(AppConstants.supportMailURL().absoluteString == "mailto:support@eonix.lk")
    }

    @Test func supportMailURLEncodesSubject() {
        let url = AppConstants.supportMailURL(subject: "Help & feedback")
        #expect(url.absoluteString == "mailto:support@eonix.lk?subject=Help%20%26%20feedback")
    }

    @Test func supportMailURLIgnoresEmptySubject() {
        #expect(AppConstants.supportMailURL(subject: "").absoluteString == "mailto:support@eonix.lk")
    }
}
