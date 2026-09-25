import Foundation
import Testing

@testable import RPCore

/// Every `.bru` fixture (Bruno's own MIT-licensed test fixtures plus RequestPad-authored ones).
let allBruFixtures: [String] = {
    let bruno = (try? FixtureLoader.files(in: "bru/bruno", withExtension: "bru")) ?? []
    let requestPad = (try? FixtureLoader.files(in: "bru/requestpad", withExtension: "bru")) ?? []
    return bruno + requestPad
}()

/// Fixtures that are request files (have a method block).
let requestBruFixtures: [String] = allBruFixtures.filter { path in
    guard let document = try? BruDocument.parse(FixtureLoader.text(path)) else { return false }
    return document.blocks.contains { BruRequestCodec.methodBlocks.contains($0.name) || $0.name == "http" }
}

@Suite("BruDocument")
struct BruDocumentTests {
    @Test func fixturesAreDiscovered() {
        #expect(allBruFixtures.count >= 18)
        #expect(requestBruFixtures.count >= 15)
    }

    @Test(arguments: allBruFixtures)
    func blockLevelRoundTripIsExact(path: String) throws {
        let text = try FixtureLoader.text(path)
        #expect(try BruDocument.parse(text).text == text)
    }

    @Test func blocksAndTrivia() throws {
        let text = "\n\nmeta {\n  name: A\n}\n\n\nget {\n  url: x\n}\n\n"
        let document = try BruDocument.parse(text)
        #expect(document.leading == "\n\n")
        #expect(document.blocks.map(\.name) == ["meta", "get"])
        #expect(document.blocks[0].trailing == "\n\n")
        #expect(document.blocks[1].line == 8)
        #expect(document.text == text)
    }

    @Test func inlineEmptyAndSquareBlocks() throws {
        let text = "headers {}\nvars:secret [\n  a,\n  b\n]\nvars:secret []"
        let document = try BruDocument.parse(text)
        #expect(document.blocks.map(\.name) == ["headers", "vars:secret", "vars:secret"])
        #expect(document.blocks[0].contentLines.isEmpty)
        #expect(document.blocks[1].lines == ["  a,", "  b"])
        #expect(document.text == text)
    }

    @Test(arguments: [
        ("get {\n  url: x\n", 1), ("meta {\n}\njunk\n", 3), ("  indented {\n}\n", 1), ("1abc {\n}", 1), ("meta\n", 1),
    ])
    func syntaxErrors(text: String, line: Int) {
        #expect {
            try BruDocument.parse(text)
        } throws: { error in
            guard case .bruSyntax(let position, _) = error as? CoreError else { return false }
            return position.line == line
        }
    }

    @Test func sizeLimit() {
        let big = "docs {\n" + String(repeating: "  x\n", count: BruDocument.maximumBytes / 4 + 10) + "}\n"
        #expect(throws: CoreError.inputTooLarge(limitBytes: BruDocument.maximumBytes)) { try BruDocument.parse(big) }
    }
}

@Suite("BruDictionary")
struct BruDictionaryTests {
    func pairs(_ lines: [String]) throws -> [BruPair] { try BruDictionary.parse(lines: lines, firstLine: 2) }

    @Test func keysValuesAndFlags() throws {
        let parsed = try pairs([
            "  plain: value with: colon", "  ~disabled: x", "  \"quoted key\": 1", "  ~\"q \\\"x\\\"\": 2",
            "  empty:", "    key:value", "  url: https://a/b?c=d",
        ])
        #expect(parsed.map(\.key) == ["plain", "disabled", "quoted key", "q \"x\"", "empty", "key", "url"])
        #expect(parsed.map(\.text) == ["value with: colon", "x", "1", "2", "", "value", "https://a/b?c=d"])
        #expect(parsed.map(\.isDisabled) == [false, true, false, true, false, false, false])
    }

    @Test func multilineListsAndAnnotations() throws {
        let parsed = try pairs([
            "  @description('first')", "  @required", "  body: '''", "    line 1", "      indented", "",
            "  ''' @contentType(application/json)",
            "  tags: [", "    a", "", "    b", "  ]", "  @orderNumber: res.body.x", "  @multi('''", "  long text",
            "  ''')", "  after: 1",
        ])
        #expect(parsed.count == 4)
        #expect(parsed[0].annotations == ["@description('first')", "@required"])
        #expect(parsed[0].value == .multiline("line 1\n  indented\n", suffix: "@contentType(application/json)"))
        #expect(parsed[0].text == "line 1\n  indented\n @contentType(application/json)")
        #expect(parsed[1].value == .list(["a", "b"]))
        #expect(parsed[1].text == "a,b")
        #expect(parsed[2].key == "@orderNumber")
        #expect(parsed[3].annotations == ["@multi('''\n  long text\n  ''')"])
    }

    @Test(arguments: [
        ["  no colon here"], ["  \"unterminated: x"], ["  \"q\" x"], ["  a: '''", "  never closed"], ["  a: [", "  b"],
    ])
    func errors(lines: [String]) {
        #expect(throws: CoreError.self) { try pairs(lines) }
    }

    @Test func serializationQuotesAndRoundTrips() throws {
        let original = [
            BruPair(key: "a b", text: "1"), BruPair(key: "c:\"d\"", text: "2", isDisabled: true),
            BruPair(key: "multi", text: "x\ny"), BruPair(key: "tags", value: .list(["t1"])),
            BruPair(key: "note", text: "", annotations: ["@description('hi')"]),
            BruPair(key: "json", value: .multiline("{\n}", suffix: "@contentType(application/json)")),
        ]
        let lines = BruDictionary.lines(for: original)
        #expect(lines.first == "  \"a b\": 1")
        #expect(lines[1] == "  ~\"c:\\\"d\\\"\": 2")
        #expect(try BruDictionary.parse(lines: lines, firstLine: 1) == original)
        #expect(BruDictionary.keyString("simple") == "simple")
    }

    @Test func textBlocks() throws {
        let document = try BruDocument.parse("docs {\n\n  # Title\n\n    code\n  last\n}\n")
        #expect(BruText.text(of: document.blocks[0]) == "# Title\n\n  code\nlast")
        #expect(BruText.lines(for: "a\n\nb") == ["  a", "  ", "  b"])
        #expect(BruText.lines(for: "").isEmpty)
    }
}

@Suite("BruRequestCodec")
struct BruRequestCodecTests {
    @Test(arguments: requestBruFixtures)
    func unchangedRequestReproducesFileExactly(path: String) throws {
        let text = try FixtureLoader.text(path)
        let (request, document) = try BruRequestCodec.decode(text)
        #expect(try BruRequestCodec.encode(request, preserving: document) == text)
    }

    @Test(arguments: requestBruFixtures)
    func freshEncodingDecodesToSameRequest(path: String) throws {
        let (request, _) = try BruRequestCodec.decode(try FixtureLoader.text(path))
        let fresh = try BruRequestCodec.encode(request)
        let (reread, _) = try BruRequestCodec.decode(fresh)
        var expected = request
        // Script blocks are not written for new files; everything RequestPad models must survive.
        expected.hasUnsupportedScripts = false
        #expect(reread.hasSameContent(as: expected))
        // A second fresh encoding is stable.
        #expect(try BruRequestCodec.encode(reread) == fresh)
    }

    @Test func decodesBrunoReferenceRequest() throws {
        let (request, _) = try BruRequestCodec.decode(try FixtureLoader.text("bru/bruno/request.bru"))
        #expect(request.name == "Send Bulk SMS")
        #expect(request.tags == ["foo", "bar"])
        #expect(request.method == .get)
        #expect(request.url == "https://api.textlocal.in/send/:id")
        #expect(
            request.queryParams.map(\.name) == [
                "apiKey", "numbers", "key with spaces", "colon:parameter", "nested escaped \"quote\"", "{braces}",
                "disabled:colon:parameter", "message",
            ])
        #expect(request.queryParams.map(\.isEnabled) == [true, true, true, true, true, true, false, false])
        #expect(request.pathParams == [KeyValue(name: "id", value: "123")])
        #expect(request.headers.count == 8)
        #expect(request.auth == .bearer(token: "123"))
        #expect(request.body == .json("{\n  \"hello\": \"world\"\n}"))
        #expect(request.variables.map(\.name) == ["departingDate", "returningDate"])
        #expect(request.extractors.map(\.variableName) == ["token", "@orderNumber", "petId", "@transactionId"])
        #expect(request.extractors[0].source == .body(path: "$.token"))
        #expect(request.extractors.map(\.isEnabled) == [true, true, false, false])
        #expect(request.assertions.count == 2)
        #expect(request.assertions[0].source == .status)
        #expect(request.assertions[0].operation == .equals)
        #expect(request.assertions[0].operand == "200")
        #expect(!request.assertions[1].isEnabled)
        #expect(request.hasUnsupportedScripts)
        #expect(request.docs == "This request needs auth token to be set in the headers.")
    }

    @Test func decodesRequestPadFixtures() throws {
        let (upload, _) = try BruRequestCodec.decode(try FixtureLoader.text("bru/requestpad/multipart-files.bru"))
        #expect(upload.auth == .inherit)
        guard case .multipart(let fields) = upload.body else {
            Issue.record("Expected multipart")
            return
        }
        #expect(fields.map(\.name) == ["caption", "avatar", "attachments", "draft", "metadata"])
        #expect(fields[1].content == .files(["images/avatar.png"]))
        #expect(fields[1].contentType == "image/png")
        #expect(fields[2].content == .files(["docs/a.pdf", "docs/b.pdf"]))
        #expect(fields[2].contentType == nil)
        #expect(!fields[3].isEnabled)
        #expect(fields[4].content == .text("{\n  \"source\": \"requestpad\"\n}"))
        #expect(fields[4].contentType == "application/json")

        let (graphQL, _) = try BruRequestCodec.decode(try FixtureLoader.text("bru/requestpad/graphql.bru"))
        #expect(graphQL.kind == .graphql)
        #expect(graphQL.auth == .none)
        guard case .graphQL(let body) = graphQL.body else {
            Issue.record("Expected GraphQL")
            return
        }
        #expect(body.query.hasPrefix("query Launches($limit: Int) {"))
        #expect(body.variables == "{\n  \"limit\": {{limit}}\n}")
        #expect(
            graphQL.extractors.map(\.source) == [.body(path: "$.data.launchesPast[0].mission_name"), .header("etag")])
        #expect(!graphQL.extractors[0].persistToEnvironment)
        #expect(graphQL.extractors[1].persistToEnvironment)
        #expect(graphQL.assertions.map(\.operation) == [.equals, .exists, .notExists, .contains, nil])
        #expect(graphQL.assertions[3].operand == "\"Falcon\"")
        #expect(graphQL.assertions.map(\.isSupported) == [true, true, true, true, false])

        let (oauth, _) = try BruRequestCodec.decode(
            try FixtureLoader.text("bru/requestpad/oauth2-client-credentials.bru"))
        guard case .oauth2(let config) = oauth.auth else {
            Issue.record("Expected OAuth2")
            return
        }
        #expect(config.grantType == .clientCredentials)
        #expect(config.accessTokenURL == "https://auth.example.com/oauth/token")
        #expect(config.clientID == "{{clientId}}")
        #expect(config.scope == "items:read")
        #expect(config.credentialsPlacement == .basicAuthHeader)
        #expect(config.autoRefreshToken)
        #expect(
            oauth.settings == RequestSettings(followRedirects: false, maximumRedirects: 10, timeoutMilliseconds: 5000))
        #expect(oauth.docs == "Lists items.\n\nRequires the `items:read` scope.")

        let (form, _) = try BruRequestCodec.decode(try FixtureLoader.text("bru/requestpad/form-crlf.bru"))
        #expect(
            form.body
                == .formURLEncoded([
                    KeyValue(name: "username", value: "{{user}}"), KeyValue(name: "password", value: "{{password}}"),
                    KeyValue(name: "remember me", value: "on"),
                ]))
    }

    @Test func customMethodsUseHTTPBlock() throws {
        let (request, document) = try BruRequestCodec.decode(
            try FixtureLoader.text("bru/bruno/custom-method-with-special-chars.bru"))
        #expect(request.method.rawValue == "CUSTOM@METHOD")
        #expect(!request.method.isValidForSending)
        #expect(document.firstBlock(named: "http") != nil)
        #expect(HTTPMethod(lenientBruValue: "HAS SPACE") == nil)
        #expect(HTTPMethod(lenientBruValue: "") == nil)
        #expect(HTTPMethod.get.isValidForSending)
    }

    @Test func editingURLChangesOnlyTheMethodBlock() throws {
        let text = try FixtureLoader.text("bru/bruno/request.bru")
        let (request, document) = try BruRequestCodec.decode(text)
        var edited = request
        edited.url = "https://api.textlocal.in/v2/send/:id"
        let output = try BruRequestCodec.encode(edited, preserving: document)
        #expect(
            output
                == text.replacingOccurrences(
                    of: "url: https://api.textlocal.in/send/:id", with: "url: https://api.textlocal.in/v2/send/:id"))
    }

    @Test func switchingBodyAndAuthPreservesInactiveBlocks() throws {
        let text = try FixtureLoader.text("bru/bruno/request.bru")
        let (request, document) = try BruRequestCodec.decode(text)
        var edited = request
        edited.body = .text("new text")
        edited.auth = .basic(username: "jane", password: "{{pw}}")
        let output = try BruRequestCodec.encode(edited, preserving: document)
        let reread = try BruDocument.parse(output)
        #expect(reread.firstBlock(named: "body:json")?.source == document.firstBlock(named: "body:json")?.source)
        #expect(reread.firstBlock(named: "auth:bearer")?.source == document.firstBlock(named: "auth:bearer")?.source)
        #expect(BruText.text(of: try #require(reread.firstBlock(named: "body:text"))) == "new text")
        let decoded = try BruRequestCodec.decode(reread)
        #expect(decoded.body == .text("new text"))
        #expect(decoded.auth == .basic(username: "jane", password: "{{pw}}"))
        #expect(
            reread.firstBlock(named: "script:pre-request")?.source
                == document.firstBlock(named: "script:pre-request")?.source)
        #expect(reread.firstBlock(named: "body:sparql") != nil)
    }

    @Test func addingAndRemovingBlocksKeepsCanonicalOrder() throws {
        let text =
            "meta {\n  name: A\n  type: http\n  seq: 1\n}\n\nget {\n  url: https://x\n  body: none\n  auth: none\n}\n\ndocs {\n  Hi\n}\n"
        let (request, document) = try BruRequestCodec.decode(text)
        var edited = request
        edited.headers = [KeyValue(name: "Accept", value: "*/*")]
        edited.docs = ""
        let output = try BruRequestCodec.encode(edited, preserving: document)
        #expect(
            output
                == "meta {\n  name: A\n  type: http\n  seq: 1\n}\n\nget {\n  url: https://x\n  body: none\n  auth: none\n}\n\nheaders {\n  Accept: */*\n}\n"
        )
    }

    @Test func methodChangeRenamesBlockAndKeepsUnknownKeys() throws {
        let text =
            "meta {\n  name: A\n  type: http\n  seq: 1\n}\n\nget {\n  url: https://x\n  body: none\n  auth: none\n  custom: kept\n}\n"
        let (request, document) = try BruRequestCodec.decode(text)
        var edited = request
        edited.method = .post
        let output = try BruRequestCodec.encode(edited, preserving: document)
        #expect(output.contains("post {\n  url: https://x\n  body: none\n  auth: none\n  custom: kept\n}"))
        #expect(!output.contains("get {"))
        var custom = request
        custom.method = try #require(HTTPMethod(rawValue: "PURGE"))
        let purge = try BruRequestCodec.encode(custom, preserving: document)
        #expect(purge.contains("http {\n  method: PURGE\n  url: https://x"))
        let (reread, _) = try BruRequestCodec.decode(purge)
        #expect(reread.method.rawValue == "PURGE")
    }

    @Test func settingsMergeKeepsUnknownKeysAndDefaultsAreOmitted() throws {
        let text = try FixtureLoader.text("bru/requestpad/oauth2-client-credentials.bru")
        let (request, document) = try BruRequestCodec.decode(text)
        var edited = request
        edited.settings.timeoutMilliseconds = nil
        let output = try BruRequestCodec.encode(edited, preserving: document)
        // Bruno reads `timeout: 0` as "use the default".
        #expect(output.contains("settings {\n  encodeUrl: true\n  followRedirects: false\n  timeout: 0\n}"))
        let fresh = try BruRequestCodec.encode(RequestItem(name: "n", url: "https://x"))
        #expect(!fresh.contains("settings"))
        #expect(
            fresh == "meta {\n  name: n\n  type: http\n  seq: 1\n}\n\nget {\n  url: https://x\n  auth: inherit\n}\n")
    }

    @Test func crlfFilesStayCRLFWhenUnchangedAndEditsKeepOtherLines() throws {
        let text = try FixtureLoader.text("bru/requestpad/form-crlf.bru")
        let (request, document) = try BruRequestCodec.decode(text)
        var edited = request
        edited.name = "Sign in"
        let output = try BruRequestCodec.encode(edited, preserving: document)
        #expect(output.hasSuffix("  \"remember me\": on\r\n}\r\n"))
        #expect(try BruRequestCodec.decode(output).request.name == "Sign in")
    }

    @Test func extractorAndAssertionEditing() throws {
        var request = RequestItem(name: "r", url: "https://x")
        var extractor = Extractor(variableName: "id", source: .body(path: "$.data.id"))
        extractor.persistToEnvironment = true
        extractor.setSource(.body(path: "$.data['user id']"))
        request.extractors = [extractor]
        request.assertions = [
            Assertion(source: .status, operation: .equals, operand: "201"),
            Assertion(source: .header("etag"), operation: .exists),
        ]
        let text = try BruRequestCodec.encode(request)
        #expect(text.contains("vars:post-response {\n  @persist\n  id: res.body.data[\"user id\"]\n}"))
        #expect(text.contains("assert {\n  res.status: eq 201\n  res.headers.etag: isDefined\n}"))
        let (decoded, _) = try BruRequestCodec.decode(text)
        #expect(decoded.extractors[0].source == .body(path: "$.data['user id']"))
        #expect(decoded.extractors[0].persistToEnvironment)
        #expect(decoded.assertions == request.assertions)
    }

    @Test(arguments: [
        ("meta {\n  name: x\n}\n", "no method block"), ("http {\n  method: BAD METHOD\n  url: x\n}\n", "method"),
    ])
    func invalidRequests(text: String, hint: String) {
        #expect(throws: CoreError.self) { try BruRequestCodec.decode(text) }
    }

    @Test func assertionOperatorParsing() {
        #expect(
            Assertion.fromBru(key: "res.status", value: "200", isEnabled: true, annotations: []).operation == .equals)
        #expect(
            Assertion.fromBru(key: "res.status", value: "neq 404", isEnabled: true, annotations: []).operand == "404")
        #expect(
            Assertion.fromBru(key: "res.body.a", value: "isDefined", isEnabled: true, annotations: []).operation
                == .exists)
        #expect(
            Assertion.fromBru(key: "res.body.a", value: "isDefined extra", isEnabled: true, annotations: []).operation
                == nil)
        #expect(
            Assertion.fromBru(key: "res.body.a", value: "matches ^a", isEnabled: true, annotations: []).operation == nil
        )
        #expect(!Assertion.fromBru(key: "req.x", value: "eq 1", isEnabled: true, annotations: []).isSupported)
        #expect(Assertion.Operator.exists.isUnary)
        #expect(!Assertion.Operator.equals.isUnary)
    }
}
