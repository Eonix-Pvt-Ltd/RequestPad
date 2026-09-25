import Foundation
import RPCore
import RPData
import Testing

@testable import RPServices

/// Integration tests of the live client against Local Echo over loopback (no internet access needed).
@Suite("URLSessionHTTPClient", .serialized)
struct URLSessionHTTPClientTests {
    let temporary = FileManager.default.temporaryDirectory.appending(
        path: "http-\(UUID().uuidString)", directoryHint: .isDirectory)
    let resolver = RequestResolver(interpolator: Interpolator())

    func withEcho(
        _ body: (URL, URLSessionHTTPClient) async throws -> Void, configuration: HTTPClientConfiguration? = nil
    ) async throws {
        let server = LocalEchoServer()
        try await server.start()
        let base = try #require(await server.baseURL)
        let client = URLSessionHTTPClient(
            configuration: configuration ?? HTTPClientConfiguration(temporaryDirectory: temporary))
        do {
            try await body(base, client)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
        try? FileManager.default.removeItem(at: temporary)
    }

    func resolved(_ request: RequestItem) throws -> ResolvedRequest {
        try resolver.resolve(request, context: ResolutionContext())
    }

    @Test(.timeLimit(.minutes(1)))
    func sendsRequestsAndReportsMetrics() async throws {
        try await withEcho { base, client in
            let request = RequestItem(
                name: "r", method: .post, url: base.absoluteString + "/items?x=1",
                headers: [KeyValue(name: "X-One", value: "1"), KeyValue(name: "X-Empty", value: "")],
                body: .json(#"{"a":[1,2]}"#),
                auth: .bearer(token: "tkn"))
            let response = try await client.send(try resolved(request), files: PathFileResolver(baseDirectory: nil))
            #expect(response.statusCode == 200)
            #expect(
                response.reasonPhrase == "No Error" || response.reasonPhrase == "Ok" || !response.reasonPhrase.isEmpty)
            #expect(response.contentType == "application/json")
            let echo = try JSONParser().parse(try #require(response.body.inMemoryData))
            #expect(echo["method"] == .string("POST"))
            #expect(echo["query"]?["x"] == .array([.string("1")]))
            #expect(echo["headers"]?["X-One"] == .string("1"))
            #expect(echo["headers"]?["Authorization"] == .string("Bearer tkn"))
            #expect(echo["body"]?["json"]?["a"]?[1] == .number(2))
            let timings = try #require(response.timings)
            #expect(timings.total > 0)
            #expect(response.remoteAddress?.hasPrefix("127.0.0.1:") == true)
            #expect(response.networkProtocol == "http/1.1")
            #expect(response.tlsVersion == nil)
            #expect(response.totalBytes > response.body.size)
            #expect(response.snapshot().jsonBody?["method"] == .string("POST"))
            #expect(response.summary().statusCode == 200)
            #expect(response.summary().contentType == "application/json")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func statusCodesCookiesAndHead() async throws {
        try await withEcho { base, client in
            let files = PathFileResolver(baseDirectory: nil)
            let notFound = try await client.send(
                try resolved(RequestItem(name: "r", url: base.absoluteString + "/status/404")), files: files)
            #expect(notFound.statusCode == 404)
            #expect(notFound.statusClass == .clientError)
            let cookies = try await client.send(
                try resolved(RequestItem(name: "r", url: base.absoluteString + "/cookies/set?session=abc&theme=dark")),
                files: files)
            #expect(cookies.setCookieHeaders.sorted() == ["session=abc; Path=/", "theme=dark; Path=/"])
            #expect(!cookies.headers.contains { $0.name.lowercased() == "set-cookie" })
            var jar = CookieJar()
            jar.store(setCookieHeaders: cookies.setCookieHeaders, from: cookies.url, now: Date())
            #expect(jar.headerValue(for: base, now: Date())?.contains("session=abc") == true)
            let head = try await client.send(
                try resolved(RequestItem(name: "r", method: .head, url: base.absoluteString + "/")), files: files)
            #expect(head.statusCode == 200)
            #expect(head.body.size == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func redirectPolicy() async throws {
        try await withEcho { base, client in
            let files = PathFileResolver(baseDirectory: nil)
            let followed = try await client.send(
                try resolved(RequestItem(name: "r", url: base.absoluteString + "/redirect/3")), files: files)
            #expect(followed.statusCode == 200)
            #expect(followed.redirects.map(\.statusCode) == [302, 302, 302])
            #expect(followed.url.path() == "/redirect/0")

            var notFollowing = RequestItem(name: "r", url: base.absoluteString + "/redirect/3")
            notFollowing.settings.followRedirects = false
            let stopped = try await client.send(try resolved(notFollowing), files: files)
            #expect(stopped.statusCode == 302)
            #expect(stopped.headerValue("Location") == "/redirect/2")

            var limited = RequestItem(name: "r", url: base.absoluteString + "/redirect/5")
            limited.settings.maximumRedirects = 2
            await #expect(throws: ServiceError.tooManyRedirects(2)) {
                try await client.send(try resolved(limited), files: files)
            }

            // Cross-origin redirect (127.0.0.1 → localhost) drops credentials.
            let port = try #require(base.port)
            let target = "http://localhost:\(port)/after"
            let crossOrigin = RequestItem(
                name: "r",
                url: base.absoluteString
                    + "/redirect-to?url=\(target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")",
                headers: [KeyValue(name: "Cookie", value: "a=1"), KeyValue(name: "X-Keep", value: "yes")],
                auth: .bearer(token: "secret"))
            let after = try await client.send(try resolved(crossOrigin), files: files)
            let echo = try JSONParser().parse(try #require(after.body.inMemoryData))
            #expect(echo["path"] == .string("/after"))
            #expect(echo["headers"]?["Authorization"] == nil)
            #expect(echo["headers"]?["Cookie"] == nil)
            #expect(echo["headers"]?["X-Keep"] == .string("yes"))
            #expect(SessionDelegate.origin(of: try #require(URL(string: "https://a.com/x"))) == "https://a.com:443")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func largeBodiesSpillToDiskAndLimitsApply() async throws {
        let small = HTTPClientConfiguration(
            maximumInMemoryBodyBytes: 1024 * 1024, maximumBodyBytes: 4 * 1024 * 1024, temporaryDirectory: temporary)
        try await withEcho(
            { base, client in
                let files = PathFileResolver(baseDirectory: nil)
                let big = try await client.send(
                    try resolved(RequestItem(name: "r", url: base.absoluteString + "/bytes/3000000")), files: files)
                guard case .file(let url, let size) = big.body else {
                    Issue.record("Expected a file-backed body")
                    return
                }
                #expect(size == 3_000_000)
                let data = try Data(contentsOf: url)
                #expect(data.count == 3_000_000)
                #expect(data[1_000_001] == UInt8(truncatingIfNeeded: 1_000_001))
                #expect(big.body.inMemoryData == nil)
                #expect(big.body.prefix(4) == Data([0, 1, 2, 3]))
                #expect(big.snapshot().jsonBody == nil)
                let memory = try await client.send(
                    try resolved(RequestItem(name: "r", url: base.absoluteString + "/bytes/1000")), files: files)
                #expect(memory.body.inMemoryData?.count == 1000)
                await #expect(throws: ServiceError.responseTooLarge(limitBytes: 4 * 1024 * 1024)) {
                    try await client.send(
                        try resolved(RequestItem(name: "r", url: base.absoluteString + "/bytes/6000000")), files: files)
                }
            }, configuration: small)
    }

    @Test(.timeLimit(.minutes(1)))
    func multipartUploadStreamsFiles() async throws {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let folder = temporary.appending(path: "collection", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "files"), withIntermediateDirectories: true)
        try Data("file-content-✓".utf8).write(to: folder.appending(path: "files/note.txt"))
        try await withEcho { base, client in
            let request = RequestItem(
                name: "u", method: .post, url: base.absoluteString + "/upload",
                body: .multipart([
                    MultipartField(name: "caption", content: .text("hello \"quoted\"")),
                    MultipartField(name: "doc", content: .files(["files/note.txt"])),
                    MultipartField(name: "json", content: .text("{}"), contentType: "application/json"),
                ]))
            let response = try await client.send(try resolved(request), files: PathFileResolver(baseDirectory: folder))
            let echo = try JSONParser().parse(try #require(response.body.inMemoryData))
            let contentType = echo["headers"]?["Content-Type"]?.stringValue ?? ""
            #expect(contentType.hasPrefix("multipart/form-data; boundary=RequestPadBoundary-"))
            let text = echo["body"]?["text"]?.stringValue ?? ""
            #expect(text.contains("name=\"caption\"\r\n\r\nhello \"quoted\""))
            #expect(
                text.contains("name=\"doc\"; filename=\"note.txt\"\r\nContent-Type: text/plain\r\n\r\nfile-content-✓"))
            #expect(text.contains("name=\"json\"\r\nContent-Type: application/json\r\n\r\n{}"))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.path(percentEncoded: false))
                .filter { $0.hasSuffix(".multipart") }
            #expect(leftovers.isEmpty)

            let missing = RequestItem(
                name: "u", method: .post, url: base.absoluteString,
                body: .multipart([MultipartField(name: "f", content: .files(["nope.bin"]))]))
            await #expect(throws: ServiceError.fileUnavailable(name: "nope.bin")) {
                try await client.send(try resolved(missing), files: PathFileResolver(baseDirectory: folder))
            }
            let escaping = RequestItem(
                name: "u", method: .post, url: base.absoluteString,
                body: .multipart([MultipartField(name: "f", content: .files(["../../etc/hosts"]))]))
            await #expect(throws: ServiceError.fileUnavailable(name: "../../etc/hosts")) {
                try await client.send(try resolved(escaping), files: PathFileResolver(baseDirectory: folder))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutsCancellationAndConnectionErrors() async throws {
        try await withEcho { base, client in
            let files = PathFileResolver(baseDirectory: nil)
            var slow = RequestItem(name: "r", url: base.absoluteString + "/delay/5000")
            slow.settings.timeoutMilliseconds = 1_000
            await #expect(throws: ServiceError.timedOut(seconds: 1)) {
                try await client.send(try resolved(slow), files: files)
            }

            let cancellable = Task {
                try await client.send(
                    try resolved(RequestItem(name: "r", url: base.absoluteString + "/delay/5000")), files: files)
            }
            try await Task.sleep(for: .milliseconds(200))
            let started = ContinuousClock.now
            cancellable.cancel()
            await #expect(throws: ServiceError.cancelled) { try await cancellable.value }
            #expect(ContinuousClock.now - started < .seconds(1))

            let port = try #require(base.port)
            await #expect(throws: ServiceError.self) {
                try await client.send(
                    try resolved(RequestItem(name: "r", url: "http://127.0.0.1:\(port == 1 ? 2 : 1)/")), files: files)
            }
        }
    }

    @Test func rejectsUnsendableRequestsBeforeTheNetwork() async throws {
        let client = URLSessionHTTPClient(configuration: HTTPClientConfiguration(temporaryDirectory: temporary))
        let files = PathFileResolver(baseDirectory: nil)
        let weird = ResolvedRequest(
            method: try #require(HTTPMethod(lenientBruValue: "CUSTOM@METHOD")),
            url: try #require(URL(string: "https://h")), headers: [],
            body: .none, settings: RequestSettings(), unresolvedVariables: [], containsSecrets: false, authIssue: nil)
        await #expect(throws: ServiceError.invalidMethod("CUSTOM@METHOD")) {
            try await client.send(weird, files: files)
        }
        var ftp = weird
        ftp.method = .get
        ftp.url = try #require(URL(string: "ftp://h/file"))
        await #expect(throws: ServiceError.unsupportedScheme("ftp")) { try await client.send(ftp, files: files) }
    }

    @Test func errorMappingAndMessages() {
        #expect(ServiceError.from(URLError(.timedOut), host: "h", timeoutSeconds: 7) == .timedOut(seconds: 7))
        #expect(ServiceError.from(URLError(.cannotFindHost), host: "h", timeoutSeconds: 1) == .cannotFindHost("h"))
        #expect(
            ServiceError.from(URLError(.appTransportSecurityRequiresSecureConnection), host: "h", timeoutSeconds: 1)
                == .appTransportSecurity(host: "h"))
        #expect(
            ServiceError.from(URLError(.notConnectedToInternet), host: "192.168.1.5", timeoutSeconds: 1)
                == .localNetworkDenied(host: "192.168.1.5"))
        #expect(
            ServiceError.from(URLError(.notConnectedToInternet), host: "example.com", timeoutSeconds: 1)
                == .notConnected)
        #expect(
            ServiceError.from(URLError(.notConnectedToInternet), host: "127.0.0.1", timeoutSeconds: 1) == .notConnected)
        #expect(
            ServiceError.from(URLError(.serverCertificateUntrusted), host: "h", timeoutSeconds: 1)
                == .tlsFailure(host: "h"))
        #expect(ServiceError.from(URLError(.cancelled), host: "h", timeoutSeconds: 1) == .cancelled)
        #expect(ServiceError.from(URLError(.networkConnectionLost), host: "h", timeoutSeconds: 1) == .connectionLost)
        #expect(ServiceError.from(URLError(.cannotConnectToHost), host: "h", timeoutSeconds: 1) == .cannotConnect("h"))
        #expect(
            ServiceError.from(URLError(.httpTooManyRedirects), host: "h", timeoutSeconds: 1) == .tooManyRedirects(10))
        #expect(
            ServiceError.from(URLError(.fileDoesNotExist), host: "h", timeoutSeconds: 1)
                == .fileUnavailable(name: "file"))
        #expect(ServiceError.from(ServiceError.cancelled, host: "h", timeoutSeconds: 1) == .cancelled)
        #expect(
            ServiceError.from(NSError(domain: "x", code: 5), host: "h", timeoutSeconds: 1)
                == .network(code: 5, message: NSError(domain: "x", code: 5).localizedDescription))
        if case .network = ServiceError.from(URLError(.badServerResponse), host: "h", timeoutSeconds: 1) {
        } else {
            Issue.record("expected network")
        }
        let all: [ServiceError] = [
            .invalidMethod("M"), .unsupportedScheme("ftp"), .notConnected, .timedOut(seconds: 1), .cannotFindHost("h"),
            .cannotConnect("h"),
            .connectionLost, .appTransportSecurity(host: "h"), .localNetworkDenied(host: "h"), .tlsFailure(host: "h"),
            .tooManyRedirects(3),
            .responseTooLarge(limitBytes: 5), .fileUnavailable(name: "f"), .cancelled, .network(code: 1, message: "m"),
            .echoUnavailable("x"),
            .notFound("x"),
        ]
        for error in all {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }

    @Test func tlsNamesAndMultipartHelpers() throws {
        #expect(SessionDelegate.cipherSuiteName(0x1301) == "TLS_AES_128_GCM_SHA256")
        #expect(SessionDelegate.cipherSuiteName(0xBEEF) == "0xBEEF")
        #expect(MultipartBodyWriter.escape("a\"b\r\nc") == "a%22b%0D%0Ac")
        #expect(MultipartBodyWriter.mimeType(for: try #require(URL(string: "file:///x.png"))) == "image/png")
        #expect(
            MultipartBodyWriter.mimeType(for: try #require(URL(string: "file:///x.unknownext")))
                == "application/octet-stream")
        #expect(throws: ServiceError.fileUnavailable(name: "(none)")) {
            try PathFileResolver(baseDirectory: nil).open("")
        }
        #expect(throws: ServiceError.fileUnavailable(name: "relative")) {
            try PathFileResolver(baseDirectory: nil).open("relative")
        }
    }
}

@Suite("BookmarkFileResolver")
struct BookmarkFileResolverTests {
    @Test func relativePathsInsideTheCollectionAndBookmarksOutside() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "files-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appending(path: "assets/logo.png")
        try Data([1]).write(to: inside)
        let outside = FileManager.default.temporaryDirectory.appending(path: "outside-\(UUID().uuidString).txt")
        try Data([2]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let access = PathBookmarks()

        let relative = try BookmarkFileResolver.reference(for: inside, baseDirectory: root, folderAccess: access)
        #expect(relative == "assets/logo.png")
        let bookmarked = try BookmarkFileResolver.reference(for: outside, baseDirectory: root, folderAccess: access)
        #expect(bookmarked.hasPrefix(BookmarkFileResolver.bookmarkPrefix))
        let noBase = try BookmarkFileResolver.reference(for: inside, baseDirectory: nil, folderAccess: access)
        #expect(noBase.hasPrefix(BookmarkFileResolver.bookmarkPrefix))

        let resolver = BookmarkFileResolver(baseDirectory: root, folderAccess: access)
        #expect(try resolver.open(relative).url.lastPathComponent == "logo.png")
        let (url, token) = try resolver.open(bookmarked)
        #expect(url.lastPathComponent == outside.lastPathComponent)
        token?.stop()
        #expect(throws: ServiceError.self) { try resolver.open("bookmark:not-base64!") }
        #expect(BookmarkFileResolver.displayName(for: bookmarked, folderAccess: access) == outside.lastPathComponent)
        #expect(BookmarkFileResolver.displayName(for: "a/b.png", folderAccess: access) == "b.png")
        #expect(BookmarkFileResolver.displayName(for: "bookmark:AAAA", folderAccess: access) == "Missing file")
    }
}
