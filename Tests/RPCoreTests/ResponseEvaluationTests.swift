import Foundation
import Testing

@testable import RPCore

@Suite("ResponseEvaluator")
struct ResponseEvaluatorTests {
    let response: ResponseSnapshot
    init() throws {
        response = ResponseSnapshot(
            statusCode: 201,
            headers: [
                (name: "Content-Type", value: "application/json"), (name: "Set-Cookie", value: "a=1"),
                (name: "set-cookie", value: "b=2"), (name: "X-Count", value: "42"),
            ],
            jsonBody: try JSONParser().parse(
                #"{"data":{"id":"u1","token":"abc","roles":["admin","dev"],"score":9.5,"meta":{"ok":true}},"items":[{"n":1},{"n":2}],"empty":null}"#
            ),
            responseTimeMilliseconds: 120)
    }

    func assertion(_ key: String, _ value: String) -> Assertion {
        Assertion.fromBru(key: key, value: value, isEnabled: true, annotations: [])
    }

    @Test func extractsValues() {
        let results = ResponseEvaluator.extract(
            [
                Extractor(variableName: "id", source: .body(path: "$.data.id")),
                Extractor(variableName: "@meta", source: .body(path: "$.data.meta")),
                Extractor(variableName: "ns", source: .body(path: "$.items[*].n")),
                Extractor(variableName: "status", source: .status),
                Extractor(variableName: "cookies", source: .header("set-cookie")),
                Extractor(variableName: "missing", source: .body(path: "$.nope")),
                Extractor(variableName: "bad", source: .body(path: "$[?(@.x)]")),
                Extractor(variableName: "script", source: nil, rawExpression: "res.body.map(x => x)"),
                Extractor(variableName: "off", source: .status, isEnabled: false),
                Extractor(variableName: "null", source: .body(path: "$.empty")),
            ], from: response)
        #expect(
            results.map(\.variableName) == [
                "id", "meta", "ns", "status", "cookies", "missing", "bad", "script", "null",
            ])
        #expect(results[0].outcome == .extracted("u1"))
        #expect(results[1].outcome == .extracted(#"{"ok":true}"#))
        #expect(results[2].outcome == .extracted("[1,2]"))
        #expect(results[3].outcome == .extracted("201"))
        #expect(results[4].outcome == .extracted("a=1, b=2"))
        #expect(results[5].outcome == .notFound)
        guard case .failed = results[6].outcome, case .failed = results[7].outcome else {
            Issue.record("Expected failures")
            return
        }
        #expect(results[8].outcome == .extracted("null"))
    }

    @Test func nonJSONBodies() {
        let text = ResponseSnapshot(statusCode: 200)
        #expect(
            ResponseEvaluator.extract([Extractor(variableName: "x", source: .body(path: "$.a"))], from: text)[0].outcome
                == .failed("The response body isn't JSON."))
        let result = ResponseEvaluator.evaluate([assertion("res.body.a", "eq 1")], against: text)
        #expect(result[0].didFail)
    }

    @Test(arguments: [
        ("res.status", "eq 201", true), ("res.status", "201", true), ("res.status", "neq 200", true),
        ("res.status", "eq 200", false),
        ("res.status", "gt 200", true), ("res.status", "lt 200", false), ("res.responseTime", "lt 500", true),
        ("res.body.data.id", "eq \"u1\"", true), ("res.body.data.id", "eq 'u1'", true),
        ("res.body.data.id", "eq u1", true),
        ("res.body.data.score", "eq 9.50", true), ("res.body.data.meta", "eq {\"ok\": true}", true),
        ("res.body.data.meta.ok", "eq true", true), ("res.body.empty", "eq null", true),
        ("res.body.empty", "isDefined", true),
        ("res.body.nope", "isUndefined", true), ("res.body.nope", "isDefined", false),
        ("res.body.data.id", "isUndefined", false),
        ("res.body.data.roles", "contains \"admin\"", true), ("res.body.data.roles", "notContains ops", true),
        ("res.body.data.token", "contains bc", true), ("res.body.data", "contains roles", true),
        ("res.body.data", "contains 5", false),
        ("res.body.data.score", "contains 9", true), ("res.body.nope", "contains x", false),
        ("res.headers.x-count", "eq 42", true), ("res.headers.content-type", "contains json", true),
        ("res.headers.x-count", "gt 40", true), ("res.body.data.id", "gt 3", false),
        ("res.body.data.token", "neq {{expected}}", true),
    ])
    func assertions(key: String, value: String, passes: Bool) {
        let result = ResponseEvaluator.evaluate(
            [assertion(key, value)], against: response,
            interpolate: {
                $0.replacingOccurrences(of: "{{expected}}", with: "xyz")
            })[0]
        #expect(result.didPass == passes, "\(key): \(value) → \(result.outcome)")
        #expect(result.didFail == !passes)
    }

    @Test func skippedAssertions() {
        let results = ResponseEvaluator.evaluate(
            [
                Assertion(source: .status, operation: .equals, operand: "201", isEnabled: false),
                assertion("res.body.a", "matches ^x"), assertion("req.url", "eq x"),
            ], against: response)
        #expect(results.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
    }

    @Test func invalidPathFails() {
        let result = ResponseEvaluator.evaluate(
            [Assertion(source: .body(path: "$[?bad]"), operation: .exists)], against: response)[0]
        #expect(result.didFail)
    }

    @Test func failureMessagesAreHelpful() {
        let result = ResponseEvaluator.evaluate([assertion("res.status", "eq 200")], against: response)[0]
        #expect(result.outcome == .failed("Expected 200, got 201."))
        let long = ResponseEvaluator.evaluate([assertion("res.body.data", "eq 1")], against: response)[0]
        guard case .failed(let message) = long.outcome else {
            Issue.record("Expected failure")
            return
        }
        #expect(message.count < 300)
    }

    @Test func operandParsing() {
        #expect(ResponseEvaluator.operand("  \"x y\" ") == .string("x y"))
        #expect(ResponseEvaluator.operand("12") == .number("12"))
        #expect(ResponseEvaluator.operand("[1, 2]") == .array([.number("1"), .number("2")]))
        #expect(ResponseEvaluator.operand("plain words") == .string("plain words"))
        #expect(ResponseEvaluator.operand("false") == .bool(false))
    }
}

@Suite("CookieJar")
struct CookieJarTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func url(_ string: String) throws -> URL { try #require(URL(string: string)) }

    @Test func storesAndSendsHostOnlyCookies() throws {
        var jar = CookieJar()
        jar.store(
            setCookieHeaders: ["sid=abc; Path=/; HttpOnly; SameSite=lax", "pref=1"],
            from: try url("https://app.example.com/account/settings"), now: now)
        #expect(jar.cookies.count == 2)
        #expect(jar.cookies[0].isHTTPOnly)
        #expect(jar.cookies[0].sameSite == "Lax")
        #expect(jar.cookies[1].path == "/account")
        #expect(try jar.headerValue(for: url("https://app.example.com/account/x"), now: now) == "pref=1; sid=abc")
        #expect(try jar.headerValue(for: url("https://app.example.com/other"), now: now) == "sid=abc")
        #expect(try jar.headerValue(for: url("https://sub.app.example.com/"), now: now) == nil)
    }

    @Test func domainCookiesMatchSubdomains() throws {
        var jar = CookieJar()
        jar.store(setCookieHeaders: ["d=1; Domain=.example.com"], from: try url("https://api.example.com/"), now: now)
        #expect(try jar.headerValue(for: url("https://www.example.com/"), now: now) == "d=1")
        #expect(try jar.headerValue(for: url("https://example.com/"), now: now) == "d=1")
        #expect(try jar.headerValue(for: url("https://notexample.com/"), now: now) == nil)
    }

    @Test(arguments: [
        ("a=1; Domain=other.com", "https://api.example.com/"), ("a=1; Domain=com", "https://example.com/"),
        ("a=1; Secure", "http://api.example.com/"), ("noequals", "https://h.com/"), ("=v", "https://h.com/"),
        ("a=1; Domain=1.2.3", "https://10.1.2.3/"),
    ])
    func rejectsInvalidCookies(header: String, from source: String) throws {
        var jar = CookieJar()
        jar.store(setCookieHeaders: [header], from: try url(source), now: now)
        #expect(jar.cookies.isEmpty)
    }

    @Test func secureCookiesAndLocalhost() throws {
        var jar = CookieJar()
        jar.store(setCookieHeaders: ["s=1; Secure"], from: try url("http://localhost:8080/"), now: now)
        #expect(try jar.headerValue(for: url("http://localhost:8080/api"), now: now) == "s=1")
        jar.store(setCookieHeaders: ["t=1; Secure"], from: try url("https://h.com/"), now: now)
        #expect(try jar.headerValue(for: url("http://h.com/"), now: now) == nil)
        #expect(try jar.headerValue(for: url("https://h.com/"), now: now) == "t=1")
    }

    @Test func expiryMaxAgeReplacementAndDeletion() throws {
        var jar = CookieJar()
        let site = try url("https://h.com/")
        jar.store(
            setCookieHeaders: [
                "a=1; Max-Age=60", "b=2; Expires=Wed, 21 Oct 2015 07:28:00 GMT",
                "c=3; Expires=Sun, 06 Nov 2044 08:49:37 GMT; Max-Age=10",
            ], from: site, now: now)
        #expect(jar.cookies.map(\.name) == ["a", "c"])
        #expect(jar.cookies[1].expiresAt == now.addingTimeInterval(10))
        #expect(jar.headerValue(for: site, now: now.addingTimeInterval(30)) == "a=1")
        #expect(jar.headerValue(for: site, now: now.addingTimeInterval(61)) == nil)
        let created = jar.cookies[0].createdAt
        jar.store(setCookieHeaders: ["a=updated; Max-Age=60"], from: site, now: now.addingTimeInterval(5))
        #expect(jar.cookies.first { $0.name == "a" }?.value == "updated")
        #expect(jar.cookies.first { $0.name == "a" }?.createdAt == created)
        jar.store(setCookieHeaders: ["a=; Max-Age=0"], from: site, now: now)
        #expect(!jar.cookies.contains { $0.name == "a" })
        jar.removeExpired(now: now.addingTimeInterval(100))
        #expect(jar.cookies.isEmpty)
    }

    @Test func otherDateFormatsAndLongMaxAge() throws {
        var jar = CookieJar()
        let site = try url("https://h.com/")
        jar.store(
            setCookieHeaders: [
                "a=1; Expires=Sunday, 06-Nov-44 08:49:37 GMT", "b=1; Expires=Sun Nov  6 08:49:37 2044",
                "c=1; Max-Age=999999999",
            ], from: site, now: now)
        #expect(jar.cookies.count == 3)
        #expect(jar.cookies[2].expiresAt == now.addingTimeInterval(400 * 86_400))
    }

    @Test func orderingPathMatchingAndEditing() throws {
        var jar = CookieJar()
        jar.store(setCookieHeaders: ["x=root; Path=/"], from: try url("https://h.com/"), now: now)
        jar.store(
            setCookieHeaders: ["y=deep; Path=/api/v1"], from: try url("https://h.com/"), now: now.addingTimeInterval(1))
        #expect(try jar.headerValue(for: url("https://h.com/api/v1/users"), now: now) == "y=deep; x=root")
        #expect(try jar.headerValue(for: url("https://h.com/api/v10"), now: now) == "x=root")
        #expect(CookieJar.pathMatches(requestPath: "/api/v1", cookiePath: "/api/v1"))
        #expect(CookieJar.pathMatches(requestPath: "/api/v1/x", cookiePath: "/api/"))
        #expect(CookieJar.defaultPath(for: try url("https://h.com")) == "/")
        #expect(CookieJar.defaultPath(for: try url("https://h.com/a")) == "/")
        jar.upsert(Cookie(name: "z", value: "manual", domain: "H.COM", createdAt: now), now: now)
        #expect(jar.domains == ["h.com"])
        jar.remove(id: "h.com|/|z")
        #expect(jar.cookies.count == 2)
        jar.removeAll(domain: "h.com")
        #expect(jar.cookies.isEmpty)
        jar.upsert(Cookie(name: "q", value: "1", domain: "a.com"), now: now)
        jar.removeAll()
        #expect(jar.cookies.isEmpty)
    }

    @Test func limitsAreEnforced() throws {
        var jar = CookieJar()
        let site = try url("https://h.com/")
        jar.store(setCookieHeaders: (0..<60).map { "c\($0)=v" }, from: site, now: now)
        #expect(jar.cookies.count == CookieJar.maximumCookiesPerDomain)
        jar.store(
            setCookieHeaders: ["big=" + String(repeating: "x", count: CookieJar.maximumCookieBytes)], from: site,
            now: now)
        #expect(!jar.cookies.contains { $0.name == "big" })
        var many = CookieJar()
        for index in 0..<70 {
            many.store(
                setCookieHeaders: (0..<50).map { "c\($0)=v" }, from: try url("https://d\(index).com/"),
                now: now.addingTimeInterval(Double(index)))
        }
        #expect(many.cookies.count == CookieJar.maximumCookies)
        #expect(!many.cookies.contains { $0.domain == "d0.com" })
    }

    @Test func codableRoundTrip() throws {
        var jar = CookieJar()
        jar.store(setCookieHeaders: ["a=1; Max-Age=60"], from: try url("https://h.com/"), now: now)
        let decoded = try JSONDecoder().decode(CookieJar.self, from: JSONEncoder().encode(jar))
        #expect(decoded == jar)
    }
}
