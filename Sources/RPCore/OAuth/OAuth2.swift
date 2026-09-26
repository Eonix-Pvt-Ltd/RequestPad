import CryptoKit
import Foundation

/// PKCE (RFC 7636) values for one authorization attempt.
public struct PKCEPair: Hashable, Sendable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    /// `randomBytes` returns cryptographically secure random bytes (live: `SecRandomCopyBytes`).
    public init(randomBytes: (Int) -> [UInt8]) {
        verifier = Base64URL.encode(randomBytes(48))
        challenge = Self.challenge(for: verifier)
    }

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.challenge(for: verifier)
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`. SHA-256 is only used for hashing (PKCE, token cache keys, file change
    /// detection), never for encryption (export compliance, ADR-0018).
    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Array(SHA256.hash(data: Data(verifier.utf8))))
    }
}

public enum Base64URL {
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A token returned by an OAuth 2.0 token endpoint (RFC 6749 §5.1).
public struct OAuth2Token: Hashable, Sendable, Codable {
    public var accessToken: String
    public var tokenType: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?

    public init(
        accessToken: String, tokenType: String = "Bearer", refreshToken: String? = nil, expiresAt: Date? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// Treats a token as expired 30 s early so a request never races the expiry.
    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0.addingTimeInterval(-30) <= date } ?? false
    }
}

/// OAuth 2.0 failures with user-facing messages (F05.5).
public enum OAuth2Error: Error, Hashable, Sendable, LocalizedError {
    /// An RFC 6749 §5.2 / §4.1.2.1 error response.
    case server(code: String, description: String?)
    case stateMismatch
    case missingCode
    case invalidTokenResponse(String)
    case invalidConfiguration(String)
    case userCancelled

    public var errorDescription: String? {
        switch self {
        case .server(let code, let description):
            let detail = description.map { " (\($0.prefix(200)))" } ?? ""
            switch code {
            case "invalid_client":
                return String(localized: "The client ID or secret was rejected\(detail).", bundle: .module)
            case "invalid_grant":
                return String(localized: "The authorization grant is invalid or expired\(detail).", bundle: .module)
            case "invalid_scope":
                return String(localized: "The requested scope isn't allowed\(detail).", bundle: .module)
            case "unauthorized_client":
                return String(localized: "This client isn't allowed to use this grant type\(detail).", bundle: .module)
            case "access_denied": return String(localized: "Access was denied\(detail).", bundle: .module)
            default: return String(localized: "The authorization server returned “\(code)”\(detail).", bundle: .module)
            }
        case .stateMismatch:
            return String(
                localized: "The sign-in response didn't match this request, so it was rejected for your safety.",
                bundle: .module)
        case .missingCode:
            return String(localized: "The authorization server didn't return a code.", bundle: .module)
        case .invalidTokenResponse(let reason):
            return String(localized: "The token response couldn't be read: \(reason)", bundle: .module)
        case .invalidConfiguration(let reason):
            return String(localized: "OAuth 2.0 isn't set up correctly: \(reason)", bundle: .module)
        case .userCancelled:
            return String(localized: "Sign-in was cancelled.", bundle: .module)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .userCancelled: String(localized: "Choose Get New Token to try again.", bundle: .module)
        case .invalidConfiguration:
            String(localized: "Check the token URL, client ID and redirect URI in the Auth tab.", bundle: .module)
        default: String(localized: "Check the OAuth 2.0 settings, then choose Get New Token.", bundle: .module)
        }
    }
}

/// Pure OAuth 2.0 request/response handling (RFC 6749, RFC 7636). The network and browser session are in
/// RPServices.
public enum OAuth2Flow {
    /// Builds the authorization URL for the authorization-code grant (F05.4).
    public static func authorizationURL(
        config: OAuth2Config, state: String, pkce: PKCEPair?
    ) throws(OAuth2Error) -> URL {
        guard var components = URLComponents(string: config.authorizationURL),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http", !(components.host ?? "").isEmpty
        else { throw .invalidConfiguration("The authorization URL isn't valid.") }
        guard !config.clientID.isEmpty else { throw .invalidConfiguration("Enter a client ID.") }
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.callbackURL), URLQueryItem(name: "state", value: state),
        ])
        if !config.scope.isEmpty { items.append(URLQueryItem(name: "scope", value: config.scope)) }
        if let pkce {
            items.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: pkce.method))
        }
        components.queryItems = items
        // `+` is legal in query values per RFC 3986 but many servers decode it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw .invalidConfiguration("The authorization URL isn't valid.") }
        return url
    }

    /// Extracts the authorization code from the redirect, verifying `state` (CSRF protection).
    public static func authorizationCode(from callback: URL, expectedState: String) throws(OAuth2Error) -> String {
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        var parameters: [String: String] = [:]
        for item in components?.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
        // Some servers use the fragment (response_mode=fragment).
        if let fragment = components?.fragment, parameters.isEmpty {
            for item in URLComponents(string: "?" + fragment)?.queryItems ?? [] {
                parameters[item.name] = item.value ?? ""
            }
        }
        guard parameters["state"] == expectedState else { throw .stateMismatch }
        if let error = parameters["error"] { throw .server(code: error, description: parameters["error_description"]) }
        guard let code = parameters["code"], !code.isEmpty else { throw .missingCode }
        return code
    }

    public enum Grant: Hashable, Sendable {
        case clientCredentials
        case authorizationCode(code: String, verifier: String?)
        case refresh(token: String)
    }

    /// A token endpoint request ready for URLSession.
    public struct TokenRequest: Hashable, Sendable {
        public var url: URL
        public var headers: [String: String]
        public var body: Data
    }

    public static func tokenRequest(config: OAuth2Config, grant: Grant) throws(OAuth2Error) -> TokenRequest {
        let endpoint: String
        if case .refresh = grant, !config.refreshTokenURL.isEmpty {
            endpoint = config.refreshTokenURL
        } else {
            endpoint = config.accessTokenURL
        }
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            !(url.host() ?? "").isEmpty
        else { throw .invalidConfiguration("The token URL isn't valid.") }
        guard !config.clientID.isEmpty else { throw .invalidConfiguration("Enter a client ID.") }
        var form: [(String, String)] = []
        switch grant {
        case .clientCredentials:
            form.append(("grant_type", "client_credentials"))
            if !config.scope.isEmpty { form.append(("scope", config.scope)) }
        case .authorizationCode(let code, let verifier):
            form.append(("grant_type", "authorization_code"))
            form.append(("code", code))
            form.append(("redirect_uri", config.callbackURL))
            if let verifier { form.append(("code_verifier", verifier)) }
        case .refresh(let token):
            form.append(("grant_type", "refresh_token"))
            form.append(("refresh_token", token))
        }
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"]
        switch config.credentialsPlacement {
        case .basicAuthHeader:
            // RFC 6749 §2.3.1: client credentials are form-encoded before Base64.
            let credentials =
                "\(RequestResolver.formEncode(config.clientID)):\(RequestResolver.formEncode(config.clientSecret))"
            headers["Authorization"] = "Basic " + Data(credentials.utf8).base64EncodedString()
        case .body:
            form.append(("client_id", config.clientID))
            if !config.clientSecret.isEmpty { form.append(("client_secret", config.clientSecret)) }
        }
        let body = form.map { "\(RequestResolver.formEncode($0.0))=\(RequestResolver.formEncode($0.1))" }.joined(
            separator: "&")
        return TokenRequest(url: url, headers: headers, body: Data(body.utf8))
    }

    /// Parses a token endpoint response (JSON, or form-encoded as some older servers send).
    public static func token(fromStatus status: Int, body: Data, now: Date) throws(OAuth2Error) -> OAuth2Token {
        let fields: [String: JSONValue]
        if let json = try? JSONParser(maximumBytes: 1024 * 1024, maximumDepth: 16).parse(body),
            case .object(let members) = json
        {
            fields = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        } else if let text = String(data: body, encoding: .utf8), text.contains("=") {
            var parsed: [String: JSONValue] = [:]
            for row in QueryParameters.parse(fromURL: "?" + text) { parsed[row.name] = .string(row.value) }
            fields = parsed
        } else {
            throw .invalidTokenResponse(status >= 400 ? "HTTP \(status)" : "It isn't JSON.")
        }
        if let error = fields["error"]?.stringValue {
            throw .server(code: error, description: fields["error_description"]?.stringValue)
        }
        guard (200..<300).contains(status) else { throw .invalidTokenResponse("HTTP \(status)") }
        guard let accessToken = fields["access_token"]?.stringValue, !accessToken.isEmpty else {
            throw .invalidTokenResponse("It has no access_token.")
        }
        let expiresIn: Double? = {
            switch fields["expires_in"] {
            case .number(let text), .string(let text): return Double(text)
            default: return nil
            }
        }()
        return OAuth2Token(
            accessToken: accessToken, tokenType: fields["token_type"]?.stringValue ?? "Bearer",
            refreshToken: fields["refresh_token"]?.stringValue, expiresAt: expiresIn.map { now.addingTimeInterval($0) },
            scope: fields["scope"]?.stringValue)
    }
}
