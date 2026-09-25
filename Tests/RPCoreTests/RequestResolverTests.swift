import Foundation
import Testing

@testable import RPCore

@Suite("RequestResolver")
struct RequestResolverTests {
    let secret = SecretRef(account: "env:e:token")
    var resolver: RequestResolver {
        let reference = secret
        return RequestResolver(interpolator: Interpolator(secretResolver: { $0 == reference ? "TOKEN" : nil }))
    }

    var environment: VariableContext {
        VariableContext(scopes: [
            VariableScope(
                kind: .environment,
                values: [
                    "base": .plain("https://api.example.com"), "token": .secret(secret), "user": .plain("ann"),
                ])
        ])
    }

    @Test func resolvesURLHeadersAndJSONBody() throws {
        let request = RequestItem(
            name: "Create", method: .post, url: "{{base}}/users?x={{user}}",
            headers: [KeyValue(name: "X-Trace", value: "1"), KeyValue(name: "X-Off", value: "0", isEnabled: false)],
            body: .json(#"{"name":"{{user}}"}"#), auth: .bearer(token: "{{token}}"))
        let resolved = try resolver.resolve(request, context: ResolutionContext(variables: environment))
        #expect(resolved.url.absoluteString == "https://api.example.com/users?x=ann")
        #expect(resolved.headerValue("authorization") == "Bearer TOKEN")
        #expect(resolved.headerValue("Content-Type") == "application/json")
        #expect(resolved.headerValue("X-Off") == nil)
        #expect(resolved.body == .data(Data(#"{"name":"ann"}"#.utf8)))
        #expect(resolved.containsSecrets)
        #expect(resolved.unresolvedVariables.isEmpty)
    }

    @Test func displayModeMasksSecrets() throws {
        let request = RequestItem(name: "r", url: "{{base}}", auth: .bearer(token: "{{token}}"))
        let resolved = try resolver.resolve(request, context: ResolutionContext(variables: environment), mode: .display)
        #expect(resolved.headerValue("Authorization") == "Bearer ••••••")
        #expect(!resolved.containsSecrets)
    }

    @Test func headerLayeringAndExplicitAuthorizationWins() throws {
        let collection = FolderSettings(headers: [
            KeyValue(name: "Accept", value: "text/plain"), KeyValue(name: "X-C", value: "c"),
        ])
        let folder = FolderSettings(headers: [KeyValue(name: "accept", value: "application/json")])
        let request = RequestItem(
            name: "r", url: "https://h",
            headers: [
                KeyValue(name: "Authorization", value: "Custom"), KeyValue(name: "X-Dup", value: "1"),
                KeyValue(name: "X-Dup", value: "2"),
            ],
            auth: .basic(username: "u", password: "p"))
        let resolved = try resolver.resolve(
            request, context: ResolutionContext(folders: [folder], collection: collection))
        #expect(resolved.headers.map(\.name) == ["X-C", "accept", "Authorization", "X-Dup", "X-Dup"])
        #expect(resolved.headerValue("Authorization") == "Custom")
    }

    @Test func authInheritance() {
        let request = RequestItem(name: "r", auth: .inherit)
        let collection = FolderSettings(auth: .bearer(token: "c"))
        #expect(ResolutionContext(collection: collection).effectiveAuth(for: request) == .bearer(token: "c"))
        let folders = [
            FolderSettings(auth: .basic(username: "outer", password: "")), FolderSettings(auth: .inherit),
            FolderSettings(auth: .bearer(token: "inner")),
        ]
        #expect(
            ResolutionContext(folders: folders, collection: collection).effectiveAuth(for: request)
                == .bearer(token: "inner"))
        #expect(ResolutionContext().effectiveAuth(for: request) == .none)
        #expect(
            ResolutionContext(collection: collection).effectiveAuth(for: RequestItem(name: "x", auth: .none)) == .none)
    }

    @Test func basicAuthIsBase64() throws {
        let resolved = try resolver.resolve(
            RequestItem(name: "r", url: "https://h", auth: .basic(username: "Aladdin", password: "open sesame")),
            context: ResolutionContext())
        #expect(resolved.headerValue("Authorization") == "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }

    @Test func apiKeyPlacements() throws {
        let header = try resolver.resolve(
            RequestItem(name: "r", url: "https://h/p", auth: .apiKey(APIKeyAuth(key: "X-Key", value: "k1"))),
            context: ResolutionContext())
        #expect(header.headerValue("X-Key") == "k1")
        let query = try resolver.resolve(
            RequestItem(
                name: "r", url: "https://h/p?a=1",
                auth: .apiKey(APIKeyAuth(key: "api key", value: "v&1", placement: .query))),
            context: ResolutionContext())
        #expect(query.url.absoluteString == "https://h/p?a=1&api%20key=v%261")
        let empty = try resolver.resolve(
            RequestItem(name: "r", url: "https://h", auth: .apiKey(APIKeyAuth(key: "", value: "v"))),
            context: ResolutionContext())
        #expect(empty.headers.isEmpty)
    }

    @Test func oauth2TokenPlacement() throws {
        let config = OAuth2Config(grantType: .clientCredentials)
        let request = RequestItem(name: "r", url: "https://h", auth: .oauth2(config))
        let missing = try resolver.resolve(request, context: ResolutionContext())
        #expect(missing.authIssue == .oauth2TokenRequired)
        let header = try resolver.resolve(request, context: ResolutionContext(oauth2AccessToken: "abc"))
        #expect(header.headerValue("Authorization") == "Bearer abc")
        var urlConfig = config
        urlConfig.tokenPlacement = .url
        let url = try resolver.resolve(
            RequestItem(name: "r", url: "https://h", auth: .oauth2(urlConfig)),
            context: ResolutionContext(oauth2AccessToken: "abc"))
        #expect(url.url.absoluteString == "https://h?access_token=abc")
        var noPrefix = config
        noPrefix.tokenHeaderPrefix = ""
        let raw = try resolver.resolve(
            RequestItem(name: "r", url: "https://h", auth: .oauth2(noPrefix)),
            context: ResolutionContext(oauth2AccessToken: "abc"))
        #expect(raw.headerValue("Authorization") == "abc")
    }

    @Test func unsupportedAuthIsReported() throws {
        let resolved = try resolver.resolve(
            RequestItem(name: "r", url: "https://h", auth: .unsupported(mode: "awsv4")), context: ResolutionContext())
        #expect(resolved.authIssue == .unsupportedMode("awsv4"))
    }

    @Test func formMultipartAndGraphQLBodies() throws {
        let form = try resolver.resolve(
            RequestItem(
                name: "r", method: .post, url: "https://h",
                body: .formURLEncoded([
                    KeyValue(name: "a b", value: "1&2"), KeyValue(name: "off", value: "x", isEnabled: false),
                    KeyValue(name: "u", value: "{{user}}"),
                ])), context: ResolutionContext(variables: environment))
        #expect(form.body == .data(Data("a+b=1%262&u=ann".utf8)))
        #expect(form.headerValue("Content-Type") == "application/x-www-form-urlencoded")

        let multipart = try resolver.resolve(
            RequestItem(
                name: "r", method: .post, url: "https://h",
                body: .multipart([
                    MultipartField(name: "text", content: .text("{{user}}")),
                    MultipartField(name: "file", content: .files(["a.png", "b.png"]), contentType: "image/png"),
                    MultipartField(name: "off", content: .text("x"), isEnabled: false),
                ])), context: ResolutionContext(variables: environment))
        #expect(
            multipart.body
                == .multipart([
                    .init(name: "text", content: .text("ann"), contentType: nil),
                    .init(name: "file", content: .file(reference: "a.png"), contentType: "image/png"),
                    .init(name: "file", content: .file(reference: "b.png"), contentType: "image/png"),
                ]))
        #expect(multipart.headerValue("Content-Type") == nil)

        let graphQL = try resolver.resolve(
            RequestItem(
                name: "g", kind: .graphql, method: .post, url: "https://h/graphql",
                body: .graphQL(GraphQLBody(query: "query { me }", variables: #"{"u":"{{user}}"}"#))),
            context: ResolutionContext(variables: environment))
        #expect(graphQL.body == .data(Data(#"{"query":"query { me }","variables":{"u":"ann"}}"#.utf8)))
        let noVars = try resolver.resolve(
            RequestItem(name: "g", method: .post, url: "https://h", body: .graphQL(GraphQLBody(query: "{ a }"))),
            context: ResolutionContext())
        #expect(noVars.body == .data(Data(#"{"query":"{ a }"}"#.utf8)))
    }

    @Test(arguments: [#"{"a":"#, "[1]"])
    func invalidGraphQLVariablesThrow(variables: String) {
        #expect(throws: CoreError.self) {
            try resolver.resolve(
                RequestItem(
                    name: "g", method: .post, url: "https://h",
                    body: .graphQL(GraphQLBody(query: "{a}", variables: variables))),
                context: ResolutionContext())
        }
    }

    @Test func explicitContentTypeIsKept() throws {
        let resolved = try resolver.resolve(
            RequestItem(
                name: "r", method: .post, url: "https://h",
                headers: [KeyValue(name: "content-type", value: "application/vnd.api+json")], body: .json("{}")),
            context: ResolutionContext())
        #expect(resolved.headers.filter { $0.name.lowercased() == "content-type" }.count == 1)
    }

    @Test func pathParametersAndVariablesByScope() throws {
        let request = RequestItem(
            name: "r", url: "https://h/users/:id/posts/:postId?x=:id",
            pathParams: [KeyValue(name: "id", value: "{{uid}}"), KeyValue(name: "postId", value: "a b")],
            variables: [KeyValue(name: "uid", value: "req")])
        let context = ResolutionContext(
            folders: [
                FolderSettings(variables: [KeyValue(name: "uid", value: "outer")]),
                FolderSettings(variables: [KeyValue(name: "uid", value: "inner"), KeyValue(name: "f", value: "F")]),
            ],
            collection: FolderSettings(variables: [KeyValue(name: "c", value: "C")]))
        let resolved = try resolver.resolve(request, context: context)
        #expect(resolved.url.absoluteString == "https://h/users/req/posts/a%20b?x=:id")
        var noRequestVar = request
        noRequestVar.variables = []
        #expect(
            try resolver.resolve(noRequestVar, context: context).url.absoluteString
                == "https://h/users/inner/posts/a%20b?x=:id")
    }

    @Test(arguments: [
        ("example.com/x", "https://example.com/x"), ("localhost:8080/a", "http://localhost:8080/a"),
        ("192.168.1.5/api", "http://192.168.1.5/api"), ("devbox", "http://devbox"), ("ftp://h", "ftp://h"),
        ("http://x.com", "http://x.com"), ("[::1]:80/", "http://[::1]:80/"), ("printer.local", "http://printer.local"),
    ])
    func defaultScheme(input: String, expected: String) {
        #expect(RequestResolver.addingDefaultScheme(to: input) == expected)
    }

    @Test(arguments: ["", "   ", "https://", "http://exa mple.com:99999999"])
    func invalidURLsThrow(url: String) {
        #expect(throws: CoreError.self) {
            try resolver.resolve(RequestItem(name: "r", url: url), context: ResolutionContext())
        }
    }

    @Test func unresolvedVariablesAreCollected() throws {
        let resolved = try resolver.resolve(
            RequestItem(name: "r", url: "https://h/{{a}}", headers: [KeyValue(name: "X", value: "{{b}}{{a}}")]),
            context: ResolutionContext())
        #expect(resolved.unresolvedVariables == ["a", "b"])
    }

    @Test func settingsTimeout() {
        #expect(RequestSettings().effectiveTimeout == .seconds(30))
        #expect(RequestSettings(timeoutMilliseconds: 0).effectiveTimeout == .seconds(30))
        #expect(RequestSettings(timeoutMilliseconds: 5_000).effectiveTimeout == .seconds(5))
        #expect(RequestSettings(timeoutMilliseconds: 9_999_999).effectiveTimeout == .seconds(600))
    }
}

@Suite("QueryParameters")
struct QueryParametersTests {
    @Test func parsesQuery() {
        let rows = QueryParameters.parse(fromURL: "https://h/p?a=1&b&c=&d=x%20y+z&e={{v}}#frag")
        #expect(rows.map(\.name) == ["a", "b", "c", "d", "e"])
        #expect(rows.map(\.value) == ["1", "", "", "x y z", "{{v}}"])
        #expect(QueryParameters.parse(fromURL: "https://h/p").isEmpty)
        #expect(QueryParameters.parse(fromURL: "https://h/p?").isEmpty)
    }

    @Test func rebuildsURL() {
        let rows = [
            KeyValue(name: "q", value: "a b&c"), KeyValue(name: "off", value: "1", isEnabled: false),
            KeyValue(name: "flag", value: ""), KeyValue(name: "t", value: "{{token}}"),
            KeyValue(name: "", value: "ignored"),
        ]
        #expect(
            QueryParameters.url("https://h/p?old=1#top", replacingQueryWith: rows)
                == "https://h/p?q=a%20b%26c&flag&t={{token}}#top")
        #expect(QueryParameters.url("https://h/p?old=1", replacingQueryWith: []) == "https://h/p")
    }

    @Test func mergeKeepsDisabledRowsAndIdentity() {
        let keepID = UUID()
        let existing = [
            KeyValue(id: keepID, name: "a", value: "1"), KeyValue(name: "hidden", value: "x", isEnabled: false),
            KeyValue(name: "b", value: "2"),
        ]
        let merged = QueryParameters.merge(
            urlRows: [KeyValue(name: "a", value: "9"), KeyValue(name: "c", value: "3")], into: existing)
        #expect(merged.map(\.name) == ["a", "hidden", "c"])
        #expect(merged[0].id == keepID)
        #expect(merged[0].value == "9")
        let grown = QueryParameters.merge(
            urlRows: [KeyValue(name: "x", value: ""), KeyValue(name: "y", value: "")], into: [])
        #expect(grown.map(\.name) == ["x", "y"])
    }

    @Test func roundTrip() {
        let url = "https://h/p?a=1&b=two%20words&c={{v}}"
        let rebuilt = QueryParameters.url(url, replacingQueryWith: QueryParameters.parse(fromURL: url))
        #expect(rebuilt == url)
    }
}

@Suite("LocalAddress")
struct LocalAddressTests {
    @Test(arguments: [
        ("localhost", true), ("api.localhost", true), ("printer.local", true), ("devbox", true),
        ("127.0.0.1", true), ("10.1.2.3", true), ("172.16.0.1", true), ("172.31.255.255", true), ("172.32.0.1", false),
        ("192.168.0.10", true), ("169.254.1.1", true), ("8.8.8.8", false), ("::1", true), ("[::1]", true),
        ("fe80::1", true), ("fd12::1", true), ("2001:db8::1", false), ("example.com", false), ("", false),
        ("999.1.1.1", false), ("1.2.3", false),
    ])
    func classification(host: String, isLocal: Bool) {
        #expect(LocalAddress.isLocal(host: host) == isLocal)
    }

    @Test(arguments: [
        ("localhost", true), ("127.9.9.9", true), ("[::1]", true), ("10.0.0.1", false), ("x.localhost", true),
        ("devbox", false),
    ])
    func loopback(host: String, expected: Bool) {
        #expect(LocalAddress.isLoopback(host: host) == expected)
    }
}

@Suite("BruExpression")
struct BruExpressionTests {
    @Test(arguments: [
        ("res.status", ResponseSource.status), ("res.getStatus()", .status), ("res.responseTime", .responseTime),
        ("res.body", .body(path: "$")), ("res.body.data.token", .body(path: "$.data.token")),
        ("res.body.items[0].id", .body(path: "$.items[0].id")), ("res.body[\"a b\"].c", .body(path: "$['a b'].c")),
        ("res.body['x']", .body(path: "$['x']")), ("res(\"data.id\")", .body(path: "$.data.id")),
        ("res.headers.content-type", .header("content-type")), ("res.headers[\"X-Token\"]", .header("x-token")),
        ("res.headers['etag']", .header("etag")), ("  res.status  ", .status),
    ])
    func parsesSupportedExpressions(expression: String, expected: ResponseSource) {
        #expect(BruExpression.parse(expression) == expected)
    }

    @Test(arguments: [
        "res.body.items.map(x => x.id)", "req.url", "res.body[i]", "res.body.a[", "res.headers.", "res(\"a\"b\")",
        "1 + 1", "res.body.a-b", "res.body[\"q\"x\"]", "res(\"\")",
    ])
    func rejectsUnsupportedExpressions(expression: String) {
        #expect(BruExpression.parse(expression) == nil)
    }

    @Test(arguments: [
        (ResponseSource.status, "res.status"), (.responseTime, "res.responseTime"),
        (.header("etag"), "res.headers.etag"),
        (.header("x-token"), "res.headers[\"x-token\"]"), (.body(path: "$.a[0].b"), "res.body.a[0].b"),
        (.body(path: "$['a b']"), "res.body[\"a b\"]"), (.body(path: "$"), "res.body"),
        (.body(path: "$..x"), "res.body"),
    ])
    func formats(source: ResponseSource, expected: String) {
        #expect(BruExpression.format(source) == expected)
    }

    @Test func formatParseRoundTrip() {
        for source in [ResponseSource.status, .header("x-token"), .body(path: "$.a[2]['q r']")] {
            #expect(BruExpression.parse(BruExpression.format(source)) == source)
        }
    }
}
