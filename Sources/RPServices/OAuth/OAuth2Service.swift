import AuthenticationServices
import CryptoKit
import Foundation
import RPCore
import RPData

/// Presents the provider's sign-in page and returns the redirect URL (F05.4). The live implementation uses
/// `ASWebAuthenticationSession` only — never an embedded web view (A12).
public protocol WebAuthenticator: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws(OAuth2Error) -> URL
}

/// Failures of an OAuth flow, keeping the underlying error's message.
public enum OAuthFlowError: Error, Hashable, Sendable, LocalizedError {
    case oauth(OAuth2Error)
    case network(ServiceError)
    case storage(DataError)
    /// The authorization-code grant needs the user to sign in (choose Get New Token).
    case userAuthorizationRequired

    public var errorDescription: String? {
        switch self {
        case .oauth(let error): error.errorDescription
        case .network(let error): error.errorDescription
        case .storage(let error): error.errorDescription
        case .userAuthorizationRequired:
            String(localized: "Sign in to get an access token for this request.", bundle: .module)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .oauth(let error): error.recoverySuggestion
        case .network(let error): error.recoverySuggestion
        case .storage(let error): error.recoverySuggestion
        case .userAuthorizationRequired:
            String(localized: "Open the Auth tab and choose Get New Token.", bundle: .module)
        }
    }
}

/// Obtains, caches (Keychain), refreshes and clears OAuth 2.0 tokens (F05.3, F05.4).
public actor OAuth2Service {
    private let transport: any HTTPTransport
    private let secrets: any SecretStore
    private let authenticator: any WebAuthenticator
    private let retry: RetryPolicy
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) -> [UInt8]

    public init(
        transport: any HTTPTransport, secrets: any SecretStore, authenticator: any WebAuthenticator,
        retry: RetryPolicy = RetryPolicy(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomBytes: @escaping @Sendable (Int) -> [UInt8] = OAuth2Service.secureRandomBytes
    ) {
        self.transport = transport
        self.secrets = secrets
        self.authenticator = authenticator
        self.retry = retry
        self.now = now
        self.randomBytes = randomBytes
    }

    /// Cryptographically secure random bytes (`SecRandomCopyBytes`).
    public static func secureRandomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes doesn't fail on supported OS versions; fall back to the system RNG regardless.
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes
    }

    /// The Keychain entry for a configuration's token. Configurations with the same endpoints, client and scope
    /// share a token.
    public nonisolated static func tokenReference(for config: OAuth2Config) -> SecretRef {
        let identity = [
            config.grantType.rawValue, config.accessTokenURL, config.authorizationURL, config.clientID, config.scope,
        ]
        .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return SecretRef(account: "oauth2:\(digest)")
    }

    /// A usable access token: cached, refreshed, or (client credentials) newly fetched. The authorization-code
    /// grant never opens a browser here; it throws ``OAuthFlowError/userAuthorizationRequired``.
    public func accessToken(for config: OAuth2Config) async throws(OAuthFlowError) -> String {
        if let token = try await storedToken(for: config) {
            if !token.isExpired(at: now()) { return token.accessToken }
            if config.autoRefreshToken, let refreshToken = token.refreshToken {
                do {
                    return try await exchange(config, grant: .refresh(token: refreshToken), previous: token).accessToken
                } catch {
                    try await clearToken(for: config)
                    if config.grantType == .authorizationCode { throw .userAuthorizationRequired }
                }
            }
        }
        switch config.grantType {
        case .clientCredentials: return try await exchange(config, grant: .clientCredentials, previous: nil).accessToken
        case .authorizationCode: throw .userAuthorizationRequired
        }
    }

    /// "Get New Token": always performs the grant (opening the sign-in sheet for authorization code).
    @discardableResult
    public func fetchNewToken(for config: OAuth2Config) async throws(OAuthFlowError) -> OAuth2Token {
        switch config.grantType {
        case .clientCredentials:
            return try await exchange(config, grant: .clientCredentials, previous: nil)
        case .authorizationCode:
            let state = Base64URL.encode(randomBytes(24))
            let pkce = config.usePKCE ? PKCEPair(randomBytes: randomBytes) : nil
            let authorizeURL: URL
            let callbackScheme: String
            do throws(OAuth2Error) {
                authorizeURL = try OAuth2Flow.authorizationURL(config: config, state: state, pkce: pkce)
                guard let scheme = URL(string: config.callbackURL)?.scheme, !scheme.isEmpty else {
                    throw OAuth2Error.invalidConfiguration("The callback URL isn't valid.")
                }
                callbackScheme = scheme
            } catch {
                throw .oauth(error)
            }
            let callback: URL
            do {
                callback = try await authenticator.authenticate(url: authorizeURL, callbackScheme: callbackScheme)
            } catch {
                throw .oauth(error)
            }
            let code: String
            do {
                code = try OAuth2Flow.authorizationCode(from: callback, expectedState: state)
            } catch {
                throw .oauth(error)
            }
            return try await exchange(
                config, grant: .authorizationCode(code: code, verifier: pkce?.verifier), previous: nil)
        }
    }

    public func storedToken(for config: OAuth2Config) async throws(OAuthFlowError) -> OAuth2Token? {
        let text: String?
        do {
            text = try await secrets.secret(for: Self.tokenReference(for: config))
        } catch {
            throw .storage(error)
        }
        guard let text else { return nil }
        return try? JSONDecoder().decode(OAuth2Token.self, from: Data(text.utf8))
    }

    public func clearToken(for config: OAuth2Config) async throws(OAuthFlowError) {
        do {
            try await secrets.deleteSecret(for: Self.tokenReference(for: config))
        } catch {
            throw .storage(error)
        }
    }

    private func exchange(_ config: OAuth2Config, grant: OAuth2Flow.Grant, previous: OAuth2Token?)
        async throws(OAuthFlowError) -> OAuth2Token
    {
        let tokenRequest: OAuth2Flow.TokenRequest
        do {
            tokenRequest = try OAuth2Flow.tokenRequest(config: config, grant: grant)
        } catch {
            throw .oauth(error)
        }
        var request = URLRequest(url: tokenRequest.url)
        request.httpMethod = "POST"
        request.httpBody = tokenRequest.body
        for (name, value) in tokenRequest.headers { request.setValue(value, forHTTPHeaderField: name) }
        let transport = transport
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await retry.run { () async throws(ServiceError) -> (Data, HTTPURLResponse) in
                try await transport.perform(request)
            }
        } catch {
            throw .network(error)
        }
        var token: OAuth2Token
        do {
            token = try OAuth2Flow.token(fromStatus: response.statusCode, body: data, now: now())
        } catch {
            throw .oauth(error)
        }
        // Servers may omit the refresh token on refresh; keep the previous one (RFC 6749 §6).
        if token.refreshToken == nil { token.refreshToken = previous?.refreshToken }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(token)
        } catch {
            throw .storage(.encodingFailed(what: "token"))
        }
        do {
            try await secrets.setSecret(String(decoding: encoded, as: UTF8.self), for: Self.tokenReference(for: config))
        } catch {
            throw .storage(error)
        }
        Log.logger(.oauth).info("Obtained OAuth 2.0 token from \(Log.redacted(tokenRequest.url), privacy: .public)")
        return token
    }
}

/// Live ``WebAuthenticator`` using `ASWebAuthenticationSession` in an ephemeral browser session (no shared
/// cookies — the most privacy-preserving choice). `anchor` supplies the window to present from.
public final class SystemWebAuthenticator: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding,
    @unchecked Sendable
{
    // @unchecked: `anchor` is immutable and only called on the main actor; `session` is only touched on the main actor.
    private let anchor: @MainActor @Sendable () -> ASPresentationAnchor
    @MainActor private var session: ASWebAuthenticationSession?

    public init(anchor: @escaping @MainActor @Sendable () -> ASPresentationAnchor) {
        self.anchor = anchor
    }

    public func authenticate(url: URL, callbackScheme: String) async throws(OAuth2Error) -> URL {
        let result: Result<URL, OAuth2Error> = await withCheckedContinuation { continuation in
            Task { @MainActor in
                let completion: @Sendable (URL?, Error?) -> Void = { callback, error in
                    if let callback {
                        continuation.resume(returning: .success(callback))
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(returning: .failure(.userCancelled))
                    } else {
                        continuation.resume(
                            returning: .failure(.invalidConfiguration(error?.localizedDescription ?? "Sign-in failed."))
                        )
                    }
                }
                let session: ASWebAuthenticationSession
                if #available(iOS 17.4, macOS 14.4, *) {
                    session = ASWebAuthenticationSession(
                        url: url, callback: .customScheme(callbackScheme), completionHandler: completion)
                } else {
                    session = ASWebAuthenticationSession(
                        url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() {
                    continuation.resume(
                        returning: .failure(.invalidConfiguration("The sign-in sheet couldn't be shown.")))
                }
            }
        }
        return try result.get()
    }

    @MainActor
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor()
    }
}

/// Test double: returns a scripted callback built from the authorization URL.
public actor FakeWebAuthenticator: WebAuthenticator {
    public typealias Responder = @Sendable (URL) -> Result<URL, OAuth2Error>
    private let responder: Responder
    public private(set) var presentedURLs: [URL] = []

    public init(responder: @escaping Responder) {
        self.responder = responder
    }

    public func authenticate(url: URL, callbackScheme: String) throws(OAuth2Error) -> URL {
        presentedURLs.append(url)
        return try responder(url).get()
    }
}
