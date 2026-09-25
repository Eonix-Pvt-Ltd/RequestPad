import Foundation
import Testing

@testable import RPCore

@Suite("OAuth2")
struct OAuth2Tests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func pkceMatchesRFC7636Vector() {
        // RFC 7636 Appendix B.
        let pair = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pair.method == "S256")
    }

    @Test func pkceVerifierFromRandomBytes() {
        let pair = PKCEPair(randomBytes: { Array(repeating: 0xFB, count: $0) })
        #expect(pair.verifier.count == 64)
        #expect(pair.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(Base64URL.encode([0xFB, 0xFF]) == "-_8")
    }

    var authCodeConfig: OAuth2Config {
        OAuth2Config(
            grantType: .authorizationCode, accessTokenURL: "https://auth.example.com/token",
            authorizationURL: "https://auth.example.com/authorize?audience=api", clientID: "client 1",
            clientSecret: "s:e+c",
            scope: "read write+admin")
    }

    @Test func buildsAuthorizationURL() throws {
        let pkce = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try OAuth2Flow.authorizationURL(config: authCodeConfig, state: "xyz", pkce: pkce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dictionary = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        #expect(dictionary["audience"] == "api")
        #expect(dictionary["response_type"] == "code")
        #expect(dictionary["client_id"] == "client 1")
        #expect(dictionary["redirect_uri"] == "requestpad://oauth/callback")
        #expect(dictionary["state"] == "xyz")
        #expect(dictionary["scope"] == "read write+admin")
        #expect(dictionary["code_challenge"] == pkce.challenge)
        #expect(dictionary["code_challenge_method"] == "S256")
        #expect(url.absoluteString.contains("scope=read%20write%2Badmin"))
        var noPKCE = authCodeConfig
        noPKCE.scope = ""
        let plain = try OAuth2Flow.authorizationURL(config: noPKCE, state: "s", pkce: nil)
        #expect(!plain.absoluteString.contains("code_challenge"))
        #expect(!plain.absoluteString.contains("scope"))
    }

    @Test(arguments: ["", "ftp://x/y", "not a url", "https://"])
    func rejectsBadAuthorizationURLs(url: String) {
        var config = authCodeConfig
        config.authorizationURL = url
        #expect(throws: OAuth2Error.self) { try OAuth2Flow.authorizationURL(config: config, state: "s", pkce: nil) }
    }

    @Test func requiresClientID() {
        var config = authCodeConfig
        config.clientID = ""
        #expect(throws: OAuth2Error.invalidConfiguration("Enter a client ID.")) {
            try OAuth2Flow.authorizationURL(config: config, state: "s", pkce: nil)
        }
        #expect(throws: OAuth2Error.invalidConfiguration("Enter a client ID.")) {
            try OAuth2Flow.tokenRequest(config: config, grant: .clientCredentials)
        }
    }

    @Test func parsesCallbacks() throws {
        func url(_ text: String) throws -> URL { try #require(URL(string: text)) }
        #expect(
            try OAuth2Flow.authorizationCode(
                from: url("requestpad://oauth/callback?code=abc&state=s1"), expectedState: "s1") == "abc")
        #expect(
            try OAuth2Flow.authorizationCode(
                from: url("requestpad://oauth/callback#code=frag&state=s1"), expectedState: "s1") == "frag")
        #expect(throws: OAuth2Error.stateMismatch) {
            try OAuth2Flow.authorizationCode(
                from: url("requestpad://oauth/callback?code=abc&state=evil"), expectedState: "s1")
        }
        #expect(throws: OAuth2Error.stateMismatch) {
            try OAuth2Flow.authorizationCode(from: url("requestpad://oauth/callback?code=abc"), expectedState: "s1")
        }
        #expect(throws: OAuth2Error.server(code: "access_denied", description: "User said no")) {
            try OAuth2Flow.authorizationCode(
                from: url(
                    "requestpad://oauth/callback?error=access_denied&error_description=User%20said%20no&state=s1"),
                expectedState: "s1")
        }
        #expect(throws: OAuth2Error.missingCode) {
            try OAuth2Flow.authorizationCode(from: url("requestpad://oauth/callback?state=s1"), expectedState: "s1")
        }
    }

    @Test func tokenRequestsForEachGrant() throws {
        var config = authCodeConfig
        let code = try OAuth2Flow.tokenRequest(config: config, grant: .authorizationCode(code: "c/1", verifier: "v"))
        #expect(code.url.absoluteString == "https://auth.example.com/token")
        #expect(
            String(decoding: code.body, as: UTF8.self)
                == "grant_type=authorization_code&code=c%2F1&redirect_uri=requestpad%3A%2F%2Foauth%2Fcallback&code_verifier=v"
        )
        #expect(code.headers["Authorization"] == "Basic " + Data("client+1:s%3Ae%2Bc".utf8).base64EncodedString())
        #expect(code.headers["Content-Type"] == "application/x-www-form-urlencoded")

        config.grantType = .clientCredentials
        config.credentialsPlacement = .body
        let clientCredentials = try OAuth2Flow.tokenRequest(config: config, grant: .clientCredentials)
        #expect(
            String(decoding: clientCredentials.body, as: UTF8.self)
                == "grant_type=client_credentials&scope=read+write%2Badmin&client_id=client+1&client_secret=s%3Ae%2Bc")
        #expect(clientCredentials.headers["Authorization"] == nil)

        config.refreshTokenURL = "https://auth.example.com/refresh"
        config.clientSecret = ""
        let refresh = try OAuth2Flow.tokenRequest(config: config, grant: .refresh(token: "r1"))
        #expect(refresh.url.absoluteString == "https://auth.example.com/refresh")
        #expect(
            String(decoding: refresh.body, as: UTF8.self)
                == "grant_type=refresh_token&refresh_token=r1&client_id=client+1")

        config.accessTokenURL = "mailto:x"
        #expect(throws: OAuth2Error.self) { try OAuth2Flow.tokenRequest(config: config, grant: .clientCredentials) }
    }

    @Test func parsesTokenResponses() throws {
        let json = try OAuth2Flow.token(
            fromStatus: 200,
            body: Data(
                #"{"access_token":"at","token_type":"bearer","expires_in":3600,"refresh_token":"rt","scope":"read"}"#
                    .utf8), now: now)
        #expect(
            json
                == OAuth2Token(
                    accessToken: "at", tokenType: "bearer", refreshToken: "rt", expiresAt: now.addingTimeInterval(3600),
                    scope: "read"))
        #expect(!json.isExpired(at: now.addingTimeInterval(3500)))
        #expect(json.isExpired(at: now.addingTimeInterval(3580)))
        let stringExpiry = try OAuth2Flow.token(
            fromStatus: 200, body: Data(#"{"access_token":"a","expires_in":"60"}"#.utf8), now: now)
        #expect(stringExpiry.expiresAt == now.addingTimeInterval(60))
        #expect(stringExpiry.tokenType == "Bearer")
        let form = try OAuth2Flow.token(fromStatus: 200, body: Data("access_token=f1&token_type=bearer".utf8), now: now)
        #expect(form.accessToken == "f1")
        #expect(form.expiresAt == nil)
        #expect(!form.isExpired(at: .distantFuture))
    }

    @Test(arguments: [
        (
            400, #"{"error":"invalid_client","error_description":"bad secret"}"#,
            OAuth2Error.server(code: "invalid_client", description: "bad secret")
        ),
        (400, #"{"error":"invalid_grant"}"#, .server(code: "invalid_grant", description: nil)),
        (500, "<html>oops</html>", .invalidTokenResponse("HTTP 500")),
        (200, "not a token", .invalidTokenResponse("It isn't JSON.")),
        (200, #"{"token_type":"bearer"}"#, .invalidTokenResponse("It has no access_token.")),
        (401, #"{"message":"nope"}"#, .invalidTokenResponse("HTTP 401")),
    ])
    func tokenErrors(status: Int, body: String, expected: OAuth2Error) {
        #expect(throws: expected) { try OAuth2Flow.token(fromStatus: status, body: Data(body.utf8), now: now) }
    }

    @Test func errorsHaveMessages() {
        let errors: [OAuth2Error] = [
            .server(code: "invalid_client", description: nil), .server(code: "invalid_grant", description: "x"),
            .server(code: "invalid_scope", description: nil), .server(code: "unauthorized_client", description: nil),
            .server(code: "access_denied", description: nil),
            .server(code: "temporarily_unavailable", description: nil),
            .stateMismatch, .missingCode, .invalidTokenResponse("r"), .invalidConfiguration("c"), .userCancelled,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }
}
