import Foundation
import Testing

@testable import RPCore

@Suite("ShellWords")
struct ShellWordsTests {
    @Test(arguments: [
        ("a b  c", ["a", "b", "c"]),
        ("'single $x \"q\"' \"double \\\"x\\\" \\$HOME \\\\ \\n\"", ["single $x \"q\"", "double \"x\" $HOME \\ \\n"]),
        ("$'tab\\there\\nnl \\x41\\u00e9 \\'q\\''", ["tab\there\nnl Aé 'q'"]),
        ("a\\ b c\\\nd", ["a b", "cd"]),
        ("line1 \\\r\n  line2", ["line1", "line2"]),
        ("x'y'\"z\"", ["xyz"]),
        ("''", [""]),
        ("   ", []),
        ("\"multi\\\nline\"", ["multiline"]),
        ("$'\\q\\U0001F600\\xZZ'", ["q😀\\x" + "ZZ"]),
    ])
    func splits(input: String, expected: [String]) throws {
        #expect(try ShellWords.split(input) == expected)
    }

    @Test(arguments: ["'open", "\"open", "$'open"])
    func unterminatedQuotesThrow(input: String) {
        #expect(throws: CoreError.self) { try ShellWords.split(input) }
    }

    @Test(arguments: ["plain-word_1.2/x:y=z@a,b+c%", "", "has space", "it's", "a\"b", "$HOME", "new\nline", "é"])
    func quoteRoundTrips(word: String) throws {
        #expect(try ShellWords.split(ShellWords.quote(word)) == [word])
    }
}

@Suite("CurlParser")
struct CurlParserTests {
    @Test func chromeCopyAsCurlBash() throws {
        let command = #"""
            curl 'https://api.example.com/v1/orders?status=open&limit=20' \
              -H 'accept: application/json, text/plain, */*' \
              -H 'accept-language: en-US,en;q=0.9' \
              -H 'authorization: Bearer eyJhbGciOi.abc.def' \
              -H 'content-type: application/json' \
              -b 'session=abc123; theme=dark' \
              -H 'user-agent: Mozilla/5.0 (Macintosh)' \
              --data-raw '{"items":[{"sku":"A-1","qty":2}],"note":"it'\''s a gift"}' \
              --compressed
            """#
        let result = try CurlParser.parse(command)
        let request = result.request
        #expect(request.method == .post)
        #expect(request.url == "https://api.example.com/v1/orders?status=open&limit=20")
        #expect(request.queryParams.map(\.name) == ["status", "limit"])
        #expect(request.headers.map(\.name) == ["accept", "accept-language", "authorization", "Cookie", "user-agent"])
        #expect(request.headers.lastValue(forCaseInsensitiveName: "cookie") == "session=abc123; theme=dark")
        #expect(request.body == .json(#"{"items":[{"sku":"A-1","qty":2}],"note":"it's a gift"}"#))
        #expect(request.name == "POST orders")
        #expect(result.notices.isEmpty)
    }

    @Test func firefoxStyleWithExplicitMethodAndFormData() throws {
        let command =
            "curl -X PUT \"https://h.example/form\" -H \"Content-Type: application/x-www-form-urlencoded\" --data-raw \"a=1&b=two+words&c=%26\""
        let request = try CurlParser.parse(command).request
        #expect(request.method == .put)
        #expect(
            request.body
                == .formURLEncoded([
                    KeyValue(name: "a", value: "1"), KeyValue(name: "b", value: "two words"),
                    KeyValue(name: "c", value: "&"),
                ]))
        #expect(request.headers.isEmpty)
    }

    @Test func multipartUserAuthAndTimeout() throws {
        let command =
            "curl -u admin:p@ss:word -m 2.5 -F 'name=Ann' -F 'avatar=@/tmp/a b.png;type=image/png' --form-string 'raw=@literal' https://h/upload"
        let result = try CurlParser.parse(command)
        #expect(result.request.auth == .basic(username: "admin", password: "p@ss:word"))
        #expect(result.request.settings.timeoutMilliseconds == 2500)
        #expect(result.request.method == .post)
        #expect(
            result.request.body
                == .multipart([
                    MultipartField(name: "name", content: .text("Ann")),
                    MultipartField(name: "avatar", content: .files(["/tmp/a b.png"]), contentType: "image/png"),
                    MultipartField(name: "raw", content: .text("@literal")),
                ]))
        #expect(result.notices.count == 1)
    }

    @Test func getWithDataAppendsQuery() throws {
        let request = try CurlParser.parse("curl -G https://h/search -d q=swift --data-urlencode 'tag=a b&c'").request
        #expect(request.method == .get)
        #expect(request.url == "https://h/search?q=swift&tag=a+b%26c")
        #expect(request.body == .none)
    }

    @Test func combinedShortFlagsAttachedValuesAndLongEquals() throws {
        let result = try CurlParser.parse(
            "curl -sSLkXPATCH --url=https://h/x -HAccept:text/html --data='plain text' --oauth2-bearer tkn")
        let request = result.request
        #expect(request.method == .patch)
        #expect(request.url == "https://h/x")
        #expect(
            request.headers == [
                KeyValue(name: "Accept", value: "text/html"),
                KeyValue(name: "Content-Type", value: "application/x-www-form-urlencoded"),
            ])
        #expect(request.body == .text("plain text"))
        #expect(request.auth == .bearer(token: "tkn"))
        #expect(result.notices == ["-k was ignored: RequestPad always verifies TLS certificates."])
    }

    @Test func jsonFlagAndHeadAndMiscHeaders() throws {
        let json = try CurlParser.parse(#"curl --json '{"a":1}' https://h/j"#).request
        #expect(json.method == .post)
        #expect(json.body == .json(#"{"a":1}"#))
        #expect(json.headers == [KeyValue(name: "Accept", value: "application/json")])
        let head = try CurlParser.parse("curl -I -A 'Agent/1' -e https://ref https://h").request
        #expect(head.method == .head)
        #expect(head.headers.map(\.name) == ["User-Agent", "Referer"])
        let xml = try CurlParser.parse("curl -H 'Content-Type: application/xml' -d '<a/>' https://h").request
        #expect(xml.body == .xml("<a/>"))
        #expect(xml.headers.isEmpty)
        let emptyHeader = try CurlParser.parse("curl -H 'X-Empty;' -H 'X-Remove:' https://h").request
        #expect(emptyHeader.headers == [KeyValue(name: "X-Empty", value: "")])
    }

    @Test func noticesForUnsupportedAndFileInputs() throws {
        let result = try CurlParser.parse(
            "$ curl --proxy http://p:1 --unknown-flag --data @body.json -b cookies.txt https://h extra")
        #expect(result.notices.count == 5)
        #expect(result.request.body == .none)
    }

    @Test(arguments: [
        "wget https://h", "curl", "curl -X", "curl -H 'x: y'", "curl -X 'BAD METHOD' https://h", "curl 'unterminated",
    ])
    func invalidCommands(command: String) {
        #expect(throws: CoreError.self) { try CurlParser.parse(command) }
    }

    @Test func doubleDashAndPathCurl() throws {
        #expect(try CurlParser.parse("/usr/bin/curl -- https://h/a").request.url == "https://h/a")
        #expect(try CurlParser.parse("curl.exe https://h/b").request.name == "GET b")
        #expect(CurlParser.defaultName(method: .get, url: "https://h") == "GET h")
    }

    @Test func sizeLimit() {
        let big = "curl https://h -d '" + String(repeating: "x", count: CurlParser.maximumCommandBytes) + "'"
        #expect(throws: CoreError.inputTooLarge(limitBytes: CurlParser.maximumCommandBytes)) {
            try CurlParser.parse(big)
        }
    }
}

@Suite("CurlExporter")
struct CurlExporterTests {
    let resolver = RequestResolver(interpolator: Interpolator())

    @Test func exportsReadableCommand() throws {
        let request = RequestItem(
            name: "r", method: .post, url: "https://h/items?q=a b", headers: [KeyValue(name: "X-Note", value: "it's")],
            body: .json(#"{"a":1}"#), auth: .bearer(token: "t"))
        let resolved = try resolver.resolve(request, context: ResolutionContext())
        #expect(
            CurlExporter.export(resolved, style: .singleLine)
                == #"curl -X POST 'https://h/items?q=a%20b' -L -H 'X-Note: it'\''s' -H 'Authorization: Bearer t' -H 'Content-Type: application/json' --data-raw '{"a":1}'"#
        )
        #expect(CurlExporter.export(resolved).contains(" \\\n  -H 'X-Note: it'\\''s'"))
    }

    @Test func exportsMultipartAndGetWithoutRedirects() throws {
        var request = RequestItem(
            name: "u", method: .post, url: "https://h/u",
            body: .multipart([
                MultipartField(name: "t", content: .text("hello")),
                MultipartField(name: "j", content: .text("{}"), contentType: "application/json"),
                MultipartField(name: "f", content: .files(["a.png"]), contentType: "image/png"),
            ]))
        request.settings.followRedirects = false
        let command = CurlExporter.export(
            try resolver.resolve(request, context: ResolutionContext()), style: .singleLine)
        #expect(
            command
                == "curl -X POST https://h/u --form-string t=hello -F 'j={};type=application/json' -F 'f=@a.png;type=image/png'"
        )
        let get = CurlExporter.export(
            try resolver.resolve(RequestItem(name: "g", url: "https://h"), context: ResolutionContext()),
            style: .singleLine)
        #expect(get == "curl https://h -L")
    }

    @Test func secretsAreMaskedInDisplayMode() throws {
        let secret = SecretRef(account: "s")
        let display = RequestResolver(interpolator: Interpolator(secretResolver: { _ in "REAL" }))
        let variables = VariableContext(scopes: [VariableScope(kind: .environment, values: ["token": .secret(secret)])])
        let request = RequestItem(name: "r", url: "https://h", auth: .bearer(token: "{{token}}"))
        let masked = CurlExporter.export(
            try display.resolve(request, context: ResolutionContext(variables: variables), mode: .display))
        #expect(!masked.contains("REAL"))
        #expect(masked.contains("Bearer ••••••"))
    }

    /// Property: exporting then importing yields a request that is sent identically (F07.2).
    @Test func exportImportIsWireEquivalent() throws {
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<300 {
            let original = try resolver.resolve(RandomRequest.make(using: &generator), context: ResolutionContext())
            for style in [CurlExporter.Style.singleLine, .multiLine] {
                let imported = try CurlParser.parse(CurlExporter.export(original, style: style)).request
                let reresolved = try resolver.resolve(imported, context: ResolutionContext())
                #expect(reresolved.method == original.method)
                #expect(reresolved.url == original.url)
                #expect(
                    reresolved.headers.map { [$0.name, $0.value] } == original.headers.map { [$0.name, $0.value] })
                #expect(reresolved.body == original.body)
            }
        }
    }
}

/// Deterministic xorshift generator so property tests are reproducible (B8).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

enum RandomRequest {
    static let alphabet = Array("abcXYZ019 -_.~'\"$\\&=?/:;{}[]é😀\n\t")

    static func text(using generator: inout SeededGenerator, maxLength: Int = 12) -> String {
        String(
            (0..<Int.random(in: 0...maxLength, using: &generator)).map { _ in
                alphabet.randomElement(using: &generator) ?? "a"
            })
    }

    static func token(using generator: inout SeededGenerator) -> String {
        let letters = Array("abcdefXYZ-")
        return "X-"
            + String(
                (0..<Int.random(in: 1...8, using: &generator)).map { _ in
                    letters.randomElement(using: &generator) ?? "a"
                })
    }

    static func make(using generator: inout SeededGenerator) -> RequestItem {
        let methods: [HTTPMethod] = [.get, .post, .put, .patch, .delete, .options]
        var request = RequestItem(name: "r", method: methods.randomElement(using: &generator) ?? .get)
        let segment = String(text(using: &generator).filter { $0.isLetter || $0.isNumber })
        request.url = "https://api.example.com/\(segment)?q=\(Int.random(in: 0...99, using: &generator))"
        request.headers = (0..<Int.random(in: 0...3, using: &generator)).map { _ in
            KeyValue(
                name: token(using: &generator),
                value: text(using: &generator).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(
                    in: .whitespaces))
        }
        switch Int.random(in: 0...5, using: &generator) {
        case 1:
            request.body = .json(
                #"{"v":"\#(text(using: &generator).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: ""))"}"#
            )
        case 2: request.body = .text(text(using: &generator, maxLength: 30))
        case 3: request.body = .xml("<a>\(text(using: &generator).filter { $0.isLetter })</a>")
        case 4:
            request.body = .formURLEncoded(
                (0..<Int.random(in: 1...3, using: &generator)).map { index in
                    KeyValue(name: "k\(index)", value: text(using: &generator))
                })
        case 5:
            request.body = .multipart([
                MultipartField(
                    name: "t", content: .text(String(text(using: &generator).drop(while: { $0 == "@" || $0 == "<" })))),
                MultipartField(
                    name: "f", content: .files(["dir/file \(Int.random(in: 0...9, using: &generator)).bin"]),
                    contentType: "application/octet-stream"),
            ])
        default: request.body = .none
        }
        return request
    }
}
