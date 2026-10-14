import Foundation

/// Authentication applied to a request, folder or collection (F05).
public enum RequestAuth: Hashable, Sendable, Codable {
    case inherit
    case none
    case bearer(token: String)
    case basic(username: String, password: String)
    case apiKey(APIKeyAuth)
    case oauth2(OAuth2Config)
    /// An auth mode RequestPad does not implement (e.g. Bruno `awsv4`, `digest`). Preserved on save; requests are
    /// sent without auth and the editor explains why.
    case unsupported(mode: String)

    /// Bruno's name for the mode, used in the method block's `auth:` key and the `auth:<mode>` block.
    public var bruMode: String {
        switch self {
        case .inherit: "inherit"
        case .none: "none"
        case .bearer: "bearer"
        case .basic: "basic"
        case .apiKey: "apikey"
        case .oauth2: "oauth2"
        case .unsupported(let mode): mode
        }
    }
}

public struct APIKeyAuth: Hashable, Sendable, Codable {
    public enum Placement: String, Hashable, Sendable, Codable, CaseIterable {
        case header
        /// Bruno spells query placement `queryparams`.
        case query = "queryparams"
    }

    public var key: String
    public var value: String
    public var placement: Placement

    public init(key: String, value: String, placement: Placement = .header) {
        self.key = key
        self.value = value
        self.placement = placement
    }
}

/// OAuth 2.0 configuration (F05.3, F05.4). Field names mirror Bruno's `auth:oauth2` block.
public struct OAuth2Config: Hashable, Sendable, Codable {
    public enum GrantType: String, Hashable, Sendable, Codable, CaseIterable {
        case clientCredentials = "client_credentials"
        case authorizationCode = "authorization_code"
    }

    public enum CredentialsPlacement: String, Hashable, Sendable, Codable, CaseIterable {
        case basicAuthHeader = "basic_auth_header"
        case body
    }

    public enum TokenPlacement: String, Hashable, Sendable, Codable, CaseIterable {
        case header
        case url
    }

    public var grantType: GrantType
    public var accessTokenURL: String
    public var authorizationURL: String
    public var callbackURL: String
    public var refreshTokenURL: String
    public var clientID: String
    public var clientSecret: String
    public var scope: String
    public var usePKCE: Bool
    public var credentialsPlacement: CredentialsPlacement
    public var tokenPlacement: TokenPlacement
    public var tokenHeaderPrefix: String
    public var tokenQueryKey: String
    public var autoRefreshToken: Bool

    public init(
        grantType: GrantType, accessTokenURL: String = "", authorizationURL: String = "",
        callbackURL: String = AppConstants.oauthRedirectURI, refreshTokenURL: String = "", clientID: String = "",
        clientSecret: String = "", scope: String = "", usePKCE: Bool = true,
        credentialsPlacement: CredentialsPlacement = .basicAuthHeader, tokenPlacement: TokenPlacement = .header,
        tokenHeaderPrefix: String = "Bearer", tokenQueryKey: String = "access_token", autoRefreshToken: Bool = true
    ) {
        self.grantType = grantType
        self.accessTokenURL = accessTokenURL
        self.authorizationURL = authorizationURL
        self.callbackURL = callbackURL
        self.refreshTokenURL = refreshTokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.usePKCE = usePKCE
        self.credentialsPlacement = credentialsPlacement
        self.tokenPlacement = tokenPlacement
        self.tokenHeaderPrefix = tokenHeaderPrefix
        self.tokenQueryKey = tokenQueryKey
        self.autoRefreshToken = autoRefreshToken
    }
}
