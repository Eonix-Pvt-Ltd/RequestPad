import Foundation
import RPCore
import Testing

@testable import RPServices

@Suite("EchoRequestParser")
struct EchoRequestParserTests {
    @Test func parsesIncrementallyWithContentLengthAndPipelining() throws {
        var parser = EchoRequestParser()
        parser.append(Data("POST /a?x=1 HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhel".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("loGET /b HTTP/1.1\r\nConnection: close\r\n\r\n".utf8))
        let first = try #require(try parser.next())
        #expect(first.method == "POST")
        #expect(first.path == "/a")
        #expect(first.query == "x=1")
        #expect(first.body == Data("hello".utf8))
        #expect(first.keepAlive)
        let second = try #require(try parser.next())
        #expect(second.target == "/b")
        #expect(second.query == nil)
        #expect(!second.keepAlive)
        #expect(try parser.next() == nil)
    }

    @Test func decodesChunkedBodies() throws {
        var parser = EchoRequestParser()
        parser.append(
            Data("PUT / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("0\r\n\r\n".utf8))
        #expect(try #require(try parser.next()).body == Data("Wikipedia".utf8))
    }

    @Test func http10KeepAliveSemantics() throws {
        var parser = EchoRequestParser()
        parser.append(Data("GET / HTTP/1.0\r\n\r\nGET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n".utf8))
        #expect(try #require(try parser.next()).keepAlive == false)
        #expect(try #require(try parser.next()).keepAlive)
    }

    @Test(arguments: [
        ("GARBAGE\r\n\r\n", EchoRequestParser.ParseError.malformed("request line")),
        ("GET / HTTP/1.1\r\nNoColon\r\n\r\n", .malformed("header")),
        ("GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", .malformed("Content-Length")),
        ("GET / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n", .bodyTooLarge),
        ("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", .malformed("chunk size")),
        ("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFF\r\n", .bodyTooLarge),
    ])
    func rejectsMalformedRequests(text: String, expected: EchoRequestParser.ParseError) {
        var parser = EchoRequestParser()
        parser.append(Data(text.utf8))
        #expect(throws: expected) { try parser.next() }
    }

    @Test func headerSizeLimit() {
        var parser = EchoRequestParser()
        parser.append(
            Data(
                ("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: EchoRequestParser.maximumHeaderBytes + 10))
                    .utf8))
        #expect(throws: EchoRequestParser.ParseError.headersTooLarge) { try parser.next() }
    }
}

@Suite("EchoRouter")
struct EchoRouterTests {
    func request(_ method: String, _ target: String, headers: [EchoHeader] = [], body: String = "") -> EchoRequest {
        EchoRequest(method: method, target: target, version: "HTTP/1.1", headers: headers, body: Data(body.utf8))
    }

    func json(_ response: EchoResponse) throws -> JSONValue { try JSONParser().parse(response.body) }

    @Test func echoesMethodPathQueryHeadersAndBody() throws {
        let response = EchoRouter.respond(
            to: request(
                "PATCH", "/items/7?a=1&a=2&b=x%20y",
                headers: [EchoHeader(name: "X-Test", value: "1"), EchoHeader(name: "x-test", value: "2")],
                body: #"{"k":true}"#))
        #expect(response.status == 200)
        let value = try json(response)
        #expect(value["method"] == .string("PATCH"))
        #expect(value["path"] == .string("/items/7"))
        #expect(value["query"]?["a"] == .array([.string("1"), .string("2")]))
        #expect(value["query"]?["b"] == .array([.string("x y")]))
        #expect(value["headers"]?["X-Test"] == .string("1, 2"))
        #expect(value["body"]?["json"]?["k"] == .bool(true))
        #expect(value["body"]?["size"] == .number(10))
        let binary = EchoRouter.respond(
            to: EchoRequest(method: "POST", target: "/", version: "HTTP/1.1", headers: [], body: Data([0xFF, 0xFE])))
        #expect(try json(binary)["body"]?["base64"] == .string("//4="))
    }

    @Test func statusDelayBytesImageAndCookies() throws {
        #expect(EchoRouter.respond(to: request("GET", "/status/418")).status == 418)
        #expect(EchoRouter.respond(to: request("GET", "/status/99")).status == 400)
        #expect(EchoRouter.respond(to: request("GET", "/status/abc")).status == 400)
        #expect(EchoRouter.respond(to: request("GET", "/delay/250")).delayMilliseconds == 250)
        #expect(
            EchoRouter.respond(to: request("GET", "/delay/99999")).delayMilliseconds
                == EchoRouter.maximumDelayMilliseconds)
        #expect(EchoRouter.respond(to: request("GET", "/delay/-1")).status == 400)
        let bytes = EchoRouter.respond(to: request("GET", "/bytes/300"))
        #expect(bytes.body.count == 300)
        #expect(bytes.body[257] == 1)
        #expect(EchoRouter.respond(to: request("GET", "/bytes/999999999")).status == 400)
        let image = EchoRouter.respond(to: request("GET", "/image.png"))
        #expect(image.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let cookies = EchoRouter.respond(to: request("GET", "/cookies/set?session=abc&theme=dark"))
        #expect(
            cookies.headers.filter { $0.name == "Set-Cookie" }.map(\.value) == [
                "session=abc; Path=/", "theme=dark; Path=/",
            ])
    }

    @Test func redirects() {
        let chain = EchoRouter.respond(to: request("GET", "/redirect/3"))
        #expect(chain.status == 302)
        #expect(chain.headers.first { $0.name == "Location" }?.value == "/redirect/2")
        #expect(EchoRouter.respond(to: request("GET", "/redirect/0")).status == 200)
        #expect(EchoRouter.respond(to: request("GET", "/redirect/21")).status == 400)
        let to = EchoRouter.respond(to: request("GET", "/redirect-to?url=http%3A%2F%2Flocalhost%3A9%2Fx"))
        #expect(to.status == 307)
        #expect(to.headers.first { $0.name == "Location" }?.value == "http://localhost:9/x")
        #expect(EchoRouter.respond(to: request("GET", "/redirect-to?url=https%3A%2F%2Fexample.com")).status == 400)
        #expect(EchoRouter.respond(to: request("GET", "/redirect-to")).status == 400)
    }

    @Test func oauthTokenEndpoint() throws {
        let form = [EchoHeader(name: "Content-Type", value: "application/x-www-form-urlencoded")]
        let ok = EchoRouter.respond(
            to: request(
                "POST", "/oauth/token", headers: form, body: "grant_type=client_credentials&client_id=demo&scope=read"),
            tokenID: { "fixed" })
        #expect(ok.status == 200)
        #expect(
            try json(ok)
                == JSONParser().parse(
                    #"{"access_token":"echo-fixed","token_type":"Bearer","expires_in":3600,"scope":"read"}"#))
        let basic = EchoRouter.respond(
            to: request(
                "POST", "/oauth/token", headers: form + [EchoHeader(name: "Authorization", value: "Basic ZDpz")],
                body: "grant_type=client_credentials"))
        #expect(basic.status == 200)
        #expect(EchoRouter.respond(to: request("POST", "/oauth/token", body: "grant_type=password")).status == 400)
        #expect(
            EchoRouter.respond(to: request("POST", "/oauth/token", body: "grant_type=client_credentials")).status == 401
        )
        #expect(EchoRouter.respond(to: request("GET", "/oauth/token")).status == 200)
    }

    @Test func graphQLIntrospectionAndEcho() throws {
        let introspection = EchoRouter.respond(
            to: request(
                "POST", "/graphql",
                body: #"{"query":"\#(GraphQLSchema.introspectionQuery.replacingOccurrences(of: "\n", with: " "))"}"#))
        let schema = try GraphQLSchema.fromIntrospection(try json(introspection))
        #expect(schema.queryType == "Query")
        #expect(schema.field("items", of: "Query")?.type.description == "[Item!]!")
        #expect(schema.types["Status"]?.enumValues == ["ACTIVE", "ARCHIVED"])
        let echo = EchoRouter.respond(
            to: request("POST", "/graphql", body: #"{"query":"{ hello }","variables":{"a":1}}"#))
        #expect(try json(echo)["data"]?["echo"]?["variables"]?["a"] == .number(1))
    }

    @Test func serializesResponses() {
        let text = String(
            decoding: EchoResponse(status: 201, headers: [EchoHeader(name: "X", value: "1")], body: Data("ok".utf8))
                .serialized(keepAlive: false), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 201 Created\r\nX: 1\r\nContent-Length: 2\r\nConnection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\nok"))
    }
}

@Suite("LocalEchoServer", .serialized)
struct LocalEchoServerTests {
    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    @Test(.timeLimit(.minutes(1)))
    func servesRequestsOverLoopback() async throws {
        let server = LocalEchoServer()
        let port = try await server.start()
        #expect(try await server.start() == port)
        #expect(await server.isRunning)
        let base = try #require(await server.baseURL)
        #expect(base.absoluteString == "http://127.0.0.1:\(port)")

        var post = URLRequest(
            url: base.appending(path: "echo").appending(queryItems: [URLQueryItem(name: "q", value: "1")]))
        post.httpMethod = "POST"
        post.httpBody = Data(#"{"hello":"world"}"#.utf8)
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: post)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let value = try JSONParser().parse(data)
        #expect(value["method"] == .string("POST"))
        #expect(value["body"]?["json"]?["hello"] == .string("world"))

        // Keep-alive: several sequential requests over the same session succeed.
        for code in [201, 404, 503] {
            let (_, statusResponse) = try await session.data(from: base.appending(path: "status/\(code)"))
            #expect((statusResponse as? HTTPURLResponse)?.statusCode == code)
        }
        let (bytes, _) = try await session.data(from: base.appending(path: "bytes/1048576"))
        #expect(bytes.count == 1_048_576)
        let started = ContinuousClock.now
        _ = try await session.data(from: base.appending(path: "delay/300"))
        #expect(ContinuousClock.now - started >= .milliseconds(290))
        let (_, cookieResponse) = try await session.data(
            from: base.appending(path: "cookies/set").appending(queryItems: [URLQueryItem(name: "a", value: "1")]))
        #expect((cookieResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie") == "a=1; Path=/")

        await server.stop()
        #expect(!(await server.isRunning))
        #expect(await server.baseURL == nil)
        await #expect(throws: URLError.self) { _ = try await session.data(from: base) }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsOversizedBodiesAndMalformedRequests() async throws {
        let server = LocalEchoServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let reply = try await rawExchange(port: port, request: Data("NONSENSE\r\n\r\n".utf8))
        #expect(reply.hasPrefix("HTTP/1.1 400"))
        let tooLarge = try await rawExchange(
            port: port, request: Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8))
        #expect(tooLarge.hasPrefix("HTTP/1.1 413"))
    }

    /// Sends raw bytes over TCP and returns the reply text (for requests URLSession can't produce).
    func rawExchange(port: UInt16, request: Data) async throws -> String {
        let task = session.streamTask(withHostName: "127.0.0.1", port: Int(port))
        task.resume()
        try await task.write(request, timeout: 5)
        let (data, _) = try await task.readData(ofMinLength: 1, maxLength: 4096, timeout: 5)
        task.cancel()
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}
