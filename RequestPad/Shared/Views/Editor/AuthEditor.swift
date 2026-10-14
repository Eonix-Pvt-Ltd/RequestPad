import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

/// Edits a request's, folder's or collection's authorization (F05).
struct AuthEditor: View {
    enum Mode: String, CaseIterable, Identifiable {
        case inherit, none, bearer, basic, apiKey, oauth2
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .inherit: "Inherit"
            case .none: "No Auth"
            case .bearer: "Bearer Token"
            case .basic: "Basic Auth"
            case .apiKey: "API Key"
            case .oauth2: "OAuth 2.0"
            }
        }

        init?(_ auth: RequestAuth) {
            switch auth {
            case .inherit: self = .inherit
            case .none: self = .none
            case .bearer: self = .bearer
            case .basic: self = .basic
            case .apiKey: self = .apiKey
            case .oauth2: self = .oauth2
            case .unsupported: return nil
            }
        }

        var defaultAuth: RequestAuth {
            switch self {
            case .inherit: .inherit
            case .none: .none
            case .bearer: .bearer(token: "")
            case .basic: .basic(username: "", password: "")
            case .apiKey: .apiKey(APIKeyAuth(key: "", value: ""))
            case .oauth2: .oauth2(OAuth2Config(grantType: .clientCredentials))
            }
        }
    }

    @Binding var auth: RequestAuth
    var inheritLabel: LocalizedStringKey = "Inherit from parent"
    /// OAuth token actions (only offered where a request can be resolved).
    var tokenActions: OAuthTokenActions?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Picker("Type", selection: modeBinding) {
                ForEach(Mode.allCases) { mode in
                    Text(mode == .inherit ? inheritLabel : mode.title).tag(Optional(mode))
                }
                if Mode(auth) == nil {
                    Text("Unsupported (\(auth.bruMode))").tag(Mode?.none)
                }
            }
            .accessibilityIdentifier("auth.mode")
            fields
        }
    }

    private var modeBinding: Binding<Mode?> {
        Binding(
            get: { Mode(auth) },
            set: { newValue in
                guard let newValue, newValue != Mode(auth) else { return }
                auth = newValue.defaultAuth
            })
    }

    @ViewBuilder private var fields: some View {
        switch auth {
        case .inherit:
            Text("Uses the authorization of the enclosing folder or collection.")
                .foregroundStyle(Color.textSecondary)
        case .none:
            Text("No Authorization header is sent.")
                .foregroundStyle(Color.textSecondary)
        case .bearer(let token):
            FieldRow(title: "Token") {
                RevealableField(
                    title: "Token or {{variable}}", text: Binding(get: { token }, set: { auth = .bearer(token: $0) }),
                    identifier: "auth.bearer")
            }
        case .basic(let username, let password):
            FieldRow(title: "Username") {
                TextField(
                    "Username",
                    text: Binding(get: { username }, set: { auth = .basic(username: $0, password: password) })
                )
                .textFieldStyle(.roundedBorder)
                .monospacedField()
                .accessibilityIdentifier("auth.basic.username")
            }
            FieldRow(title: "Password") {
                RevealableField(
                    title: "Password",
                    text: Binding(get: { password }, set: { auth = .basic(username: username, password: $0) }),
                    identifier: "auth.basic.password")
            }
        case .apiKey(let apiKey):
            APIKeyFields(apiKey: Binding(get: { apiKey }, set: { auth = .apiKey($0) }))
        case .oauth2(let config):
            OAuth2Fields(config: Binding(get: { config }, set: { auth = .oauth2($0) }), tokenActions: tokenActions)
        case .unsupported(let mode):
            Text("RequestPad doesn't support “\(mode)” authorization yet. The setting is kept when the file is saved.")
                .foregroundStyle(Color.textSecondary)
        }
    }
}

/// OAuth token buttons and the last result message.
struct OAuthTokenActions {
    var message: String?
    var getNewToken: () -> Void
    var clearToken: () -> Void
}

private struct APIKeyFields: View {
    @Binding var apiKey: APIKeyAuth

    var body: some View {
        FieldRow(title: "Key") {
            TextField("Header or parameter name", text: $apiKey.key)
                .textFieldStyle(.roundedBorder)
                .monospacedField()
                .accessibilityIdentifier("auth.apiKey.key")
        }
        FieldRow(title: "Value") {
            RevealableField(title: "Value or {{variable}}", text: $apiKey.value, identifier: "auth.apiKey.value")
        }
        Picker("Add To", selection: $apiKey.placement) {
            Text("Header").tag(APIKeyAuth.Placement.header)
            Text("Query Parameters").tag(APIKeyAuth.Placement.query)
        }
    }
}

private struct OAuth2Fields: View {
    @Binding var config: OAuth2Config
    let tokenActions: OAuthTokenActions?

    var body: some View {
        Picker("Grant Type", selection: $config.grantType) {
            Text("Client Credentials").tag(OAuth2Config.GrantType.clientCredentials)
            Text("Authorization Code").tag(OAuth2Config.GrantType.authorizationCode)
        }
        .accessibilityIdentifier("auth.oauth.grant")
        if config.grantType == .authorizationCode {
            urlField("Authorization URL", text: $config.authorizationURL, identifier: "auth.oauth.authorizationURL")
            FieldRow(title: "Callback URL") {
                Text(verbatim: config.callbackURL)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Toggle("Use PKCE", isOn: $config.usePKCE)
        }
        urlField("Access Token URL", text: $config.accessTokenURL, identifier: "auth.oauth.tokenURL")
        urlField("Refresh Token URL (optional)", text: $config.refreshTokenURL, identifier: "auth.oauth.refreshURL")
        FieldRow(title: "Client ID") {
            TextField("Client ID", text: $config.clientID)
                .textFieldStyle(.roundedBorder)
                .monospacedField()
                .accessibilityIdentifier("auth.oauth.clientID")
        }
        FieldRow(title: "Client Secret") {
            RevealableField(
                title: "Client secret or {{variable}}", text: $config.clientSecret,
                identifier: "auth.oauth.clientSecret")
        }
        FieldRow(title: "Scope") {
            TextField("Space-separated scopes", text: $config.scope)
                .textFieldStyle(.roundedBorder)
                .monospacedField()
        }
        Picker("Send Credentials", selection: $config.credentialsPlacement) {
            Text("As Basic Auth Header").tag(OAuth2Config.CredentialsPlacement.basicAuthHeader)
            Text("In Request Body").tag(OAuth2Config.CredentialsPlacement.body)
        }
        Picker("Add Token To", selection: $config.tokenPlacement) {
            Text("Header").tag(OAuth2Config.TokenPlacement.header)
            Text("URL").tag(OAuth2Config.TokenPlacement.url)
        }
        if config.tokenPlacement == .header {
            FieldRow(title: "Header Prefix") {
                TextField("Bearer", text: $config.tokenHeaderPrefix)
                    .textFieldStyle(.roundedBorder)
                    .monospacedField()
            }
        } else {
            FieldRow(title: "Query Parameter") {
                TextField("access_token", text: $config.tokenQueryKey)
                    .textFieldStyle(.roundedBorder)
                    .monospacedField()
            }
        }
        Toggle("Refresh Tokens Automatically", isOn: $config.autoRefreshToken)
        if let tokenActions {
            HStack {
                Button("Get New Token", action: tokenActions.getNewToken)
                    .prominentButtonStyle()
                    .accessibilityIdentifier("auth.oauth.getToken")
                Button("Clear Token", role: .destructive, action: tokenActions.clearToken)
                    .buttonStyle(.bordered)
            }
            if let message = tokenActions.message {
                Text(message)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("auth.oauth.message")
            }
            Text("Tokens are stored in the Keychain on this device only.")
                .font(.footnote)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func urlField(_ title: LocalizedStringKey, text: Binding<String>, identifier: String) -> some View {
        FieldRow(title: title) {
            TextField("https://", text: text)
                .textFieldStyle(.roundedBorder)
                .monospacedField()
                #if os(iOS)
                    .keyboardType(.URL)
                #endif
                .accessibilityIdentifier(identifier)
        }
    }
}
