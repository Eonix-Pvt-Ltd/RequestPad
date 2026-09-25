import Foundation
import RPCore
import RPData
import Testing

@testable import RPServices

@Suite("RequestExecutor", .serialized)
struct RequestExecutorTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func makeExecutor(
        client: any HTTPClient, secrets: InMemorySecretStore = InMemorySecretStore(), store: LocalStore,
        oauth: OAuth2Service? = nil
    ) -> RequestExecutor {
        RequestExecutor(
            client: client, secrets: secrets, oauth: oauth, history: store, cookies: store,
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    @Test(.timeLimit(.minutes(1)))
    func sendsAgainstLocalEchoWithSecretsCookiesExtractionAssertionsAndHistory() async throws {
        let server = LocalEchoServer()
        try await server.start()
        let base = try #require(await server.baseURL)
        defer { Task { await server.stop() } }
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let tokenRef = SecretRef(account: "env:e:token")
        let secrets = InMemorySecretStore(values: [tokenRef: "top-secret"])
        let executor = makeExecutor(client: URLSessionHTTPClient(), secrets: secrets, store: store)
        let environment = Environment(
            name: "Local",
            variables: [.plain("base", base.absoluteString), Variable(name: "token", value: .secret(tokenRef))])

        // 1. Server sets a cookie.
        var context = SendContext(environment: environment, useCookieJar: true, historyLimit: 10)
        _ = try await executor.send(
            RequestItem(name: "Login", url: "{{base}}/cookies/set?session=abc"), context: context)
        #expect(try await store.cookieJar().cookies.map(\.name) == ["session"])

        // 2. Next request sends the cookie, a secret, extracts values and asserts.
        var request = RequestItem(
            name: "Echo {{x}}", method: .post, url: "{{base}}/echo",
            body: .json(#"{"id":42,"name":"{{runtimeName}}"}"#), auth: .bearer(token: "{{token}}"))
        var persisted = Extractor(variableName: "echoedID", source: .body(path: "$.body.json.id"))
        persisted.persistToEnvironment = true
        request.extractors = [
            persisted, Extractor(variableName: "method", source: .body(path: "$.method")),
            Extractor(variableName: "missing", source: .body(path: "$.nope")),
        ]
        request.assertions = [
            Assertion(source: .status, operation: .equals, operand: "200"),
            Assertion(source: .body(path: "$.headers.Cookie"), operation: .contains, operand: "session=abc"),
            Assertion(source: .body(path: "$.body.json.name"), operation: .equals, operand: "{{runtimeName}}"),
            Assertion(source: .body(path: "$.body.json.id"), operation: .equals, operand: "41"),
        ]
        context.runtimeVariables = ["runtimeName": "Ann"]
        let result = try await executor.send(request, context: context)
        #expect(result.response.statusCode == 200)
        let echo = try JSONParser().parse(try #require(result.response.body.inMemoryData))
        #expect(echo["headers"]?["Authorization"] == .string("Bearer top-secret"))
        #expect(result.sentRequest.headerValue("Authorization") == "Bearer ••••••")
        #expect(result.runtimeVariables == ["runtimeName": "Ann", "echoedID": "42", "method": "POST"])
        #expect(result.variablesToPersist == ["echoedID": "42"])
        #expect(result.assertions.map(\.didPass) == [true, true, true, false])
        #expect(result.extractions.last?.outcome == .notFound)

        // History keeps the unresolved template: no secret, no body.
        let history = try await store.history()
        #expect(history.count == 2)
        let echoEntry = try #require(history.first { $0.request.name == "Echo {{x}}" })
        #expect(echoEntry.request.auth == .bearer(token: "{{token}}"))
        #expect(echoEntry.response.statusCode == 200)
    }

    @Test func failuresAreRecordedAndMapped() async throws {
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let failing = FakeHTTPClient { _ in .failure(.timedOut(seconds: 30)) }
        let executor = makeExecutor(client: failing, store: store)
        await #expect(throws: SendError.network(.timedOut(seconds: 30))) {
            try await executor.send(RequestItem(name: "Slow", url: "https://h"), context: SendContext())
        }
        await #expect(throws: SendError.invalidRequest(.invalidRequest(reason: "Enter a URL."))) {
            try await executor.send(RequestItem(name: "Empty"), context: SendContext())
        }
        await #expect(throws: SendError.unsupportedAuth("awsv4")) {
            try await executor.send(
                RequestItem(name: "AWS", url: "https://h", auth: .unsupported(mode: "awsv4")), context: SendContext())
        }
        let history = try await store.history()
        #expect(history.map(\.response.statusCode) == [nil, nil, nil])
        #expect(history.first { $0.request.name == "Slow" }?.response.errorSummary?.contains("30 seconds") == true)
        let quiet = makeExecutor(client: FakeHTTPClient(), store: store)
        _ = try await quiet.send(
            RequestItem(name: "Quiet", url: "https://h"), context: SendContext(recordHistory: false))
        #expect(try await store.history().count == 3)
    }

    @Test func oauthTokensAreFetchedWithInterpolatedConfigAndExplicitCookiesWin() async throws {
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        var jar = CookieJar()
        jar.upsert(Cookie(name: "jar", value: "1", domain: "h"), now: now)
        try await store.saveCookieJar(jar)
        let client = FakeHTTPClient(status: 200, json: #"{"ok":true}"#, setCookies: ["fresh=2; Path=/"])
        let transport = FakeTransport([
            { request in
                guard request.url?.absoluteString == "https://auth.local/token", form(request)["scope"] == "items:read"
                else {
                    return (400, [:], Data(#"{"error":"invalid_request"}"#.utf8))
                }
                return (200, [:], Data(#"{"access_token":"cc-token","expires_in":3600}"#.utf8))
            }
        ])
        let oauth = OAuth2Service(
            transport: transport, secrets: InMemorySecretStore(),
            authenticator: FakeWebAuthenticator { _ in .failure(.userCancelled) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let executor = makeExecutor(client: client, store: store, oauth: oauth)
        let config = OAuth2Config(
            grantType: .clientCredentials, accessTokenURL: "{{authBase}}/token", clientID: "c", scope: "{{scope}}")
        let collection = FolderSettings(
            auth: .oauth2(config),
            variables: [
                KeyValue(name: "authBase", value: "https://auth.local"), KeyValue(name: "scope", value: "items:read"),
            ])
        let request = RequestItem(
            name: "r", url: "https://h/items", headers: [KeyValue(name: "Cookie", value: "mine=0")], auth: .inherit)
        let result = try await executor.send(request, context: SendContext(collection: collection, useCookieJar: true))
        let sent = try #require(await client.requests.first)
        #expect(sent.headerValue("Authorization") == "Bearer cc-token")
        #expect(sent.headers.filter { $0.name == "Cookie" }.map(\.value) == ["mine=0"])
        #expect(result.response.statusCode == 200)
        #expect(Set(try await store.cookieJar().cookies.map(\.name)) == ["jar", "fresh"])

        let noService = makeExecutor(client: client, store: store)
        await #expect(throws: SendError.authorization(.userAuthorizationRequired)) {
            try await noService.send(request, context: SendContext(collection: collection))
        }
        let authCode = OAuth2Config(
            grantType: .authorizationCode, accessTokenURL: "https://a/t", authorizationURL: "https://a/a", clientID: "c"
        )
        await #expect(throws: SendError.authorization(.userAuthorizationRequired)) {
            try await executor.send(
                RequestItem(name: "r", url: "https://h", auth: .oauth2(authCode)), context: SendContext())
        }
    }

    @Test func errorsArePresentable() {
        for error in [
            SendError.invalidRequest(.invalidRequest(reason: "x")), .network(.notConnected),
            .authorization(.userAuthorizationRequired), .unsupportedAuth("digest"), .storage(.keychainItemNotFound),
        ] {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }
}

@Suite("CollectionRunner")
struct CollectionRunnerTests {
    func makeRunner(_ client: FakeHTTPClient, store: LocalStore) -> CollectionRunner {
        CollectionRunner(
            executor: RequestExecutor(
                client: client, secrets: InMemorySecretStore(), oauth: nil, history: store, cookies: store),
            now: { Date(timeIntervalSince1970: 0) })
    }

    func collect(_ stream: AsyncStream<RunEvent>) async -> (events: [RunEvent], report: RunReport?) {
        var events: [RunEvent] = []
        var report: RunReport?
        for await event in stream {
            events.append(event)
            if case .completed(let finished) = event { report = finished }
        }
        return (events, report)
    }

    @Test func carriesExtractedVariablesAndReports() async throws {
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let client = FakeHTTPClient { request in
            if request.url.path() == "/login" {
                return .success(
                    FakeHTTPClient.response(
                        for: request, status: 200, body: Data(#"{"token":"t-1"}"#.utf8),
                        headers: [(name: "Content-Type", value: "application/json")]))
            }
            let authorized = request.headerValue("Authorization") == "Bearer t-1"
            return .success(
                FakeHTTPClient.response(for: request, status: authorized ? 200 : 401, body: Data("{}".utf8)))
        }
        var login = RequestItem(name: "Login", method: .post, url: "https://api/login")
        login.extractors = [Extractor(variableName: "token", source: .body(path: "$.token"))]
        var me = RequestItem(name: "Me", url: "https://api/me", auth: .bearer(token: "{{token}}"))
        me.assertions = [Assertion(source: .status, operation: .equals, operand: "200")]
        var broken = RequestItem(name: "Broken", url: "https://api/broken")
        broken.assertions = [
            Assertion(source: .status, operation: .equals, operand: "201"),
            Assertion.fromBru(key: "res.body", value: "matches x", isEnabled: true, annotations: []),
        ]
        let items = [
            RunItem(request: login, displayPath: "Login"), RunItem(request: me, displayPath: "Users/Me"),
            RunItem(request: broken), RunItem(request: RequestItem(name: "Bad URL")),
        ]

        let (events, report) = await collect(
            makeRunner(client, store: store).run(
                items, context: SendContext(recordHistory: false), stopOnFailure: false))
        let finished = try #require(report)
        #expect(finished.results.map(\.outcome) == [.passed, .passed, .failed, .error])
        #expect(finished.results[1].path == "Users/Me")
        #expect(finished.results[2].assertionResults.map(\.passed) == [false, nil])
        #expect(finished.passedCount == 2)
        #expect(finished.failedCount == 2)
        #expect(!finished.wasCancelled && !finished.stoppedOnFailure)
        #expect(events.count == 9)
        let json = String(decoding: try finished.jsonData(), as: UTF8.self)
        #expect(json.contains("\"outcome\" : \"failed\""))
    }

    @Test func stopsOnFailureAndSupportsCancellation() async throws {
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let client = FakeHTTPClient(status: 500)
        var failing = RequestItem(name: "Fails", url: "https://h")
        failing.assertions = [Assertion(source: .status, operation: .equals, operand: "200")]
        let items = [RunItem(request: failing), RunItem(request: RequestItem(name: "Never", url: "https://h"))]
        let (_, report) = await collect(
            makeRunner(client, store: store).run(items, context: SendContext(recordHistory: false), stopOnFailure: true)
        )
        #expect(try #require(report).results.count == 1)
        #expect(try #require(report).stoppedOnFailure)
        #expect(await client.requests.count == 1)

        let slow = FakeHTTPClient { request in
            Thread.sleep(forTimeInterval: 0.05)
            return .success(FakeHTTPClient.response(for: request, status: 200, body: Data()))
        }
        let many = (0..<50).map { RunItem(request: RequestItem(name: "R\($0)", url: "https://h/\($0)")) }
        let consumer = Task {
            await collect(
                makeRunner(slow, store: store).run(
                    many, context: SendContext(recordHistory: false), stopOnFailure: false))
        }
        try await Task.sleep(for: .milliseconds(150))
        consumer.cancel()
        _ = await consumer.value
        #expect(await slow.requests.count < 50)
    }
}
