import Foundation
import RPCore
import RPData
import Testing

@testable import RPServices

/// Collects sleeps instead of waiting.
actor SleepRecorder {
    var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}

func instantRetry(_ recorder: SleepRecorder, attempts: Int = 3) -> RetryPolicy {
    RetryPolicy(maximumAttempts: attempts, sleep: { await recorder.record($0) }, random: { 1.0 })
}

func form(_ request: URLRequest) -> [String: String] {
    Dictionary(
        QueryParameters.parse(fromURL: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self)).map {
            ($0.name, $0.value)
        }, uniquingKeysWith: { $1 })
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test func delaysUseJitterAndRetryAfter() {
        let policy = RetryPolicy(random: { 0.5 })
        #expect(policy.delay(forRetry: 1, retryAfter: nil) == .milliseconds(250))
        #expect(policy.delay(forRetry: 3, retryAfter: nil) == .seconds(1))
        #expect(policy.delay(forRetry: 10, retryAfter: nil) == .seconds(4))
        #expect(policy.delay(forRetry: 1, retryAfter: "7") == .seconds(7))
        #expect(policy.delay(forRetry: 1, retryAfter: "9999") == .seconds(30))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(policy.delay(forRetry: 1, retryAfter: "Tue, 14 Nov 2023 22:13:25 GMT", now: now) == .seconds(5))
        #expect(policy.delay(forRetry: 1, retryAfter: "garbage") == .milliseconds(250))
        #expect(RetryPolicy.isRetryable(status: 429) && RetryPolicy.isRetryable(status: 503))
        #expect(!RetryPolicy.isRetryable(status: 501) && !RetryPolicy.isRetryable(status: 400))
    }

    @Test func retriesTransientFailuresThenSucceeds() async throws {
        let recorder = SleepRecorder()
        let transport = FakeTransport([
            { _ in (503, ["Retry-After": "2"], Data()) }, { _ in throw ServiceError.connectionLost },
            { _ in (200, [:], Data("ok".utf8)) },
        ])
        let request = URLRequest(url: try #require(URL(string: "https://h/x")))
        let (data, response) = try await instantRetry(recorder).run { () async throws(ServiceError) in
            try await transport.perform(request)
        }
        #expect(response.statusCode == 200)
        #expect(data == Data("ok".utf8))
        #expect(await recorder.durations == [.seconds(2), .seconds(1)])
    }

    @Test func givesUpAndDoesNotRetryClientErrors() async throws {
        let recorder = SleepRecorder()
        let request = URLRequest(url: try #require(URL(string: "https://h/x")))
        let failing = FakeTransport([{ _ in (500, [:], Data()) }])
        let (_, last) = try await instantRetry(recorder).run { () async throws(ServiceError) in
            try await failing.perform(request)
        }
        #expect(last.statusCode == 500)
        #expect(await failing.requests.count == 3)
        let badRequest = FakeTransport([{ _ in (400, [:], Data()) }])
        _ = try await instantRetry(recorder).run { () async throws(ServiceError) in
            try await badRequest.perform(request)
        }
        #expect(await badRequest.requests.count == 1)
        let fatal = FakeTransport([{ _ in throw ServiceError.cannotFindHost("h") }])
        await #expect(throws: ServiceError.cannotFindHost("h")) {
            try await instantRetry(recorder).run { () async throws(ServiceError) in try await fatal.perform(request) }
        }
        #expect(await fatal.requests.count == 1)
        let cancelling = RetryPolicy(sleep: { _ in throw CancellationError() })
        let flaky = FakeTransport([{ _ in (503, [:], Data()) }])
        await #expect(throws: ServiceError.cancelled) {
            try await cancelling.run { () async throws(ServiceError) in try await flaky.perform(request) }
        }
        let unscripted = FakeTransport([])
        await #expect(throws: ServiceError.self) { try await unscripted.perform(request) }
    }
}

@Suite("OAuth2Service")
struct OAuth2ServiceTests {
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))

    var clientCredentials: OAuth2Config {
        OAuth2Config(
            grantType: .clientCredentials, accessTokenURL: "https://auth.example.com/token", clientID: "cid",
            clientSecret: "sec", scope: "read")
    }

    var authorizationCode: OAuth2Config {
        OAuth2Config(
            grantType: .authorizationCode, accessTokenURL: "https://auth.example.com/token",
            authorizationURL: "https://auth.example.com/authorize",
            clientID: "app", scope: "profile", usePKCE: true)
    }

    func service(
        _ transport: FakeTransport, secrets: InMemorySecretStore = InMemorySecretStore(),
        authenticator: FakeWebAuthenticator = FakeWebAuthenticator { _ in .failure(.userCancelled) }
    ) -> OAuth2Service {
        OAuth2Service(
            transport: transport, secrets: secrets, authenticator: authenticator, retry: RetryPolicy(sleep: { _ in }),
            now: { clock.now },
            randomBytes: { Array(repeating: 7, count: $0) })
    }

    @Test func clientCredentialsAreFetchedCachedAndRenewedOnExpiry() async throws {
        let transport = FakeTransport([
            { _ in (200, [:], Data(#"{"access_token":"one","expires_in":60}"#.utf8)) },
            { _ in (200, [:], Data(#"{"access_token":"two","expires_in":60}"#.utf8)) },
        ])
        let secrets = InMemorySecretStore()
        let oauth = service(transport, secrets: secrets)
        #expect(try await oauth.accessToken(for: clientCredentials) == "one")
        #expect(try await oauth.accessToken(for: clientCredentials) == "one")
        #expect(await transport.requests.count == 1)
        let sent = try #require(await transport.requests.first)
        #expect(form(sent) == ["grant_type": "client_credentials", "scope": "read"])
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        #expect(await secrets.count == 1)
        clock.advance(by: 45)
        #expect(try await oauth.accessToken(for: clientCredentials) == "two")
        try await oauth.clearToken(for: clientCredentials)
        #expect(try await oauth.storedToken(for: clientCredentials) == nil)
    }

    @Test func authorizationCodeWithPKCEStateMachine() async throws {
        // Fake authorization server: checks the PKCE verifier against the challenge from the sign-in URL.
        let challengeBox = ChallengeBox()
        let authenticator = FakeWebAuthenticator { url in
            let items = Dictionary(
                (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }, uniquingKeysWith: { $1 })
            challengeBox.set(items["code_challenge"])
            guard items["code_challenge_method"] == "S256", let state = items["state"] else {
                return .failure(.missingCode)
            }
            return .success(URL(string: "requestpad://oauth/callback?code=auth-code&state=\(state)") ?? url)
        }
        let transport = FakeTransport([
            { request in
                let fields = form(request)
                guard fields["grant_type"] == "authorization_code", fields["code"] == "auth-code",
                    let verifier = fields["code_verifier"], PKCEPair.challenge(for: verifier) == challengeBox.value
                else { return (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8)) }
                return (200, [:], Data(#"{"access_token":"user-token","refresh_token":"r1","expires_in":10}"#.utf8))
            },
            { request in
                guard form(request) == ["grant_type": "refresh_token", "refresh_token": "r1"] else {
                    return (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8))
                }
                return (200, [:], Data(#"{"access_token":"refreshed","expires_in":3600}"#.utf8))
            },
        ])
        let oauth = service(transport, authenticator: authenticator)
        await #expect(throws: OAuthFlowError.userAuthorizationRequired) {
            try await oauth.accessToken(for: authorizationCode)
        }
        let token = try await oauth.fetchNewToken(for: authorizationCode)
        #expect(token.accessToken == "user-token")
        #expect(await authenticator.presentedURLs.count == 1)
        clock.advance(by: 60)
        #expect(try await oauth.accessToken(for: authorizationCode) == "refreshed")
        // The refresh response had no refresh_token: the previous one is kept (RFC 6749 §6).
        #expect(try await oauth.storedToken(for: authorizationCode)?.refreshToken == "r1")
    }

    @Test func forgedStateIsRejected() async throws {
        let attacker = FakeWebAuthenticator { url in
            .success(URL(string: "requestpad://oauth/callback?code=stolen&state=forged") ?? url)
        }
        let transport = FakeTransport([{ _ in (200, [:], Data(#"{"access_token":"never"}"#.utf8)) }])
        let oauth = service(transport, authenticator: attacker)
        await #expect(throws: OAuthFlowError.oauth(.stateMismatch)) {
            try await oauth.fetchNewToken(for: authorizationCode)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func cancellationServerErrorsAndFailedRefresh() async throws {
        let cancelled = service(
            FakeTransport([]), authenticator: FakeWebAuthenticator { _ in .failure(.userCancelled) })
        await #expect(throws: OAuthFlowError.oauth(.userCancelled)) {
            try await cancelled.fetchNewToken(for: authorizationCode)
        }

        let rejecting = service(
            FakeTransport([
                { _ in (401, [:], Data(#"{"error":"invalid_client","error_description":"bad secret"}"#.utf8)) }
            ]))
        await #expect(throws: OAuthFlowError.oauth(.server(code: "invalid_client", description: "bad secret"))) {
            try await rejecting.accessToken(for: clientCredentials)
        }
        let offline = service(FakeTransport([{ _ in throw ServiceError.notConnected }]))
        await #expect(throws: OAuthFlowError.network(.notConnected)) {
            try await offline.accessToken(for: clientCredentials)
        }

        var badConfig = authorizationCode
        badConfig.callbackURL = "no scheme"
        await #expect(throws: OAuthFlowError.self) { try await cancelled.fetchNewToken(for: badConfig) }

        // An expired auth-code token whose refresh fails requires signing in again.
        let secrets = InMemorySecretStore()
        let expired = OAuth2Token(
            accessToken: "old", refreshToken: "dead", expiresAt: clock.now.addingTimeInterval(-10))
        await secrets.setSecret(
            String(decoding: try JSONEncoder().encode(expired), as: UTF8.self),
            for: OAuth2Service.tokenReference(for: authorizationCode))
        let refreshFails = service(
            FakeTransport([{ _ in (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8)) }]), secrets: secrets)
        await #expect(throws: OAuthFlowError.userAuthorizationRequired) {
            try await refreshFails.accessToken(for: authorizationCode)
        }
        #expect(await secrets.count == 0)
    }

    @Test func tokenReferencesAreStableAndDistinct() {
        #expect(
            OAuth2Service.tokenReference(for: clientCredentials) == OAuth2Service.tokenReference(for: clientCredentials)
        )
        var other = clientCredentials
        other.scope = "write"
        #expect(OAuth2Service.tokenReference(for: other) != OAuth2Service.tokenReference(for: clientCredentials))
        #expect(OAuth2Service.tokenReference(for: clientCredentials).account.hasPrefix("oauth2:"))
        #expect(OAuth2Service.secureRandomBytes(32).count == 32)
        #expect(OAuth2Service.secureRandomBytes(16) != OAuth2Service.secureRandomBytes(16))
        for error in [
            OAuthFlowError.oauth(.missingCode), .network(.notConnected), .storage(.keychainItemNotFound),
            .userAuthorizationRequired,
        ] {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func clientCredentialsAgainstLocalEcho() async throws {
        let server = LocalEchoServer()
        try await server.start()
        let base = try #require(await server.baseURL)
        defer { Task { await server.stop() } }
        let config = OAuth2Config(
            grantType: .clientCredentials, accessTokenURL: base.absoluteString + "/oauth/token", clientID: "demo",
            clientSecret: "s", credentialsPlacement: .body)
        let oauth = OAuth2Service(
            transport: URLSessionTransport(), secrets: InMemorySecretStore(),
            authenticator: FakeWebAuthenticator { _ in .failure(.userCancelled) })
        let token = try await oauth.accessToken(for: config)
        #expect(token.hasPrefix("echo-"))
    }
}

final class TestClock: @unchecked Sendable {
    // @unchecked: `current` is only accessed under `lock`.
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class ChallengeBox: @unchecked Sendable {
    // @unchecked: `stored` is only accessed under `lock`.
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ newValue: String?) { lock.withLock { stored = newValue } }
}

@Suite("GraphQLSchemaService")
struct GraphQLSchemaServiceTests {
    @Test(.timeLimit(.minutes(1)))
    func fetchesFromLocalEchoAndCaches() async throws {
        let server = LocalEchoServer()
        try await server.start()
        let base = try #require(await server.baseURL)
        defer { Task { await server.stop() } }
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let service = GraphQLSchemaService(
            transport: URLSessionTransport(), cache: store, now: { Date(timeIntervalSince1970: 5) })
        let endpoint = base.appending(path: "graphql")
        #expect(try await service.cachedSchema(for: endpoint) == nil)
        let schema = try await service.schema(
            for: endpoint, headers: [(name: "Authorization", value: "Bearer x"), (name: "Content-Length", value: "1")])
        #expect(schema.queryType == "Query")
        #expect(try await service.cachedSchema(for: endpoint)?.fetchedAt == Date(timeIntervalSince1970: 5))
        await server.stop()
        // Served from the cache while the server is down; a forced refresh needs the network.
        #expect(try await service.schema(for: endpoint, headers: []).queryType == "Query")
        await #expect(throws: SchemaFetchError.self) {
            try await service.schema(for: endpoint, headers: [], forceRefresh: true)
        }
    }

    @Test func httpAndSchemaErrors() async throws {
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let endpoint = try #require(URL(string: "https://api.example.com/graphql?x=1"))
        let forbidden = GraphQLSchemaService(
            transport: FakeTransport([{ _ in (403, [:], Data("nope".utf8)) }]), cache: store,
            retry: RetryPolicy(sleep: { _ in }))
        await #expect(throws: SchemaFetchError.http(status: 403)) {
            try await forbidden.schema(for: endpoint, headers: [])
        }
        let disabled = GraphQLSchemaService(
            transport: FakeTransport([
                { _ in (200, [:], Data(#"{"errors":[{"message":"Introspection disabled"}]}"#.utf8)) }
            ]), cache: store)
        await #expect(throws: SchemaFetchError.self) { try await disabled.schema(for: endpoint, headers: []) }
        #expect(GraphQLSchemaService.cacheKey(for: endpoint) == "https://api.example.com/graphql")
        #expect(
            GraphQLSchemaService.cacheKey(for: try #require(URL(string: "HTTP://Host:8080"))) == "http://host:8080/")
        for error in [
            SchemaFetchError.network(.notConnected), .http(status: 500), .invalidSchema(.invalidRequest(reason: "x")),
            .storage(.saveFailed(underlying: "x")),
        ] {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }
}
