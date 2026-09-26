import Foundation
import Testing

@testable import RPCore

// Uses the seeded `SeededGenerator` from CurlTests.swift (deterministic: failures reproduce).

/// Generates hostile inputs from seed documents: random bytes, and seeds with chunks deleted, duplicated,
/// swapped or replaced by syntax-heavy tokens.
struct Mutator {
    static let tokens = [
        "{", "}", "[", "]", "\"", "'", "\\", "\n", "\r\n", ":", ",", "#", "{{", "}}", "~", "---", "&a", "*a", "!!",
        "- ", "  ", "\t", "\u{0}", "\u{FFFD}", "é", "💥", "$", "..", "[*]", "?(@", "'''", "\"\"\"", "%", "=", ";", "|",
        String(repeating: "[", count: 300), String(repeating: "{\"a\":", count: 200),
        String(repeating: "- ", count: 200),
    ]

    var generator: SeededGenerator

    mutating func input(from seeds: [String]) -> String {
        switch Int.random(in: 0..<10, using: &generator) {
        case 0: return randomText(length: Int.random(in: 0..<600, using: &generator))
        case 1:
            return String(
                decoding: (0..<Int.random(in: 0..<600, using: &generator)).map { _ in
                    UInt8.random(in: 0...255, using: &generator)
                }, as: UTF8.self)
        default:
            var text = Array(seeds.randomElement(using: &generator) ?? "")
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                text = mutate(text)
            }
            return String(text.prefix(20_000))
        }
    }

    private mutating func mutate(_ text: [Character]) -> [Character] {
        var text = text
        let count = text.count
        let position = count == 0 ? 0 : Int.random(in: 0...count, using: &generator)
        let length = count == 0 ? 0 : Int.random(in: 0...min(40, count - min(position, count)), using: &generator)
        let range = position..<min(position + length, count)
        switch Int.random(in: 0..<5, using: &generator) {
        case 0: text.removeSubrange(range)
        case 1: text.insert(contentsOf: Array(Self.tokens.randomElement(using: &generator) ?? ""), at: position)
        case 2: text.insert(contentsOf: Array(text[range]), at: min(position, text.count))
        case 3: text.replaceSubrange(range, with: Array(Self.tokens.randomElement(using: &generator) ?? ""))
        default:
            if count > 1 {
                let other = Int.random(in: 0..<count, using: &generator)
                text.swapAt(min(position, count - 1), other)
            }
        }
        return text
    }

    private mutating func randomText(length: Int) -> String {
        let alphabet = Array("abcXYZ019 {}[]\"':,\\\n\t-#~@$.*?&!|=/<>%+é💥")
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "a" })
    }
}

/// B2 / Phase 7: every parser that reads untrusted text returns or throws — never crashes, hangs or recurses without
/// bound — on thousands of hostile inputs. Also runs under ASan and TSan in `scripts/test.sh --sanitizers`.
@Suite("Fuzzing")
struct FuzzTests {
    static let iterations = 2_000

    static let jsonSeeds = [
        #"{"a":[1,2.5e3,-0,true,false,null],"b":{"c":"\u00e9\n"}}"#, "[]", "\"x\"", "123",
        #"{"deep":[[[[{"k":"v"}]]]]}"#,
    ]
    static let yamlSeeds = [
        "openapi: 3.0.0\ninfo: {title: T, version: '1'}\npaths:\n  /a:\n    get: {summary: A}\n",
        "a: &x [1, 2]\nb: *x\nc: |\n  text\n  more\nd: >-\n  folded\n", "- a\n- b: c\n  d: [e, {f: g}]\n",
    ]
    static let bruSeeds = [
        "meta {\n  name: Get\n  type: http\n  seq: 1\n}\n\nget {\n  url: {{base}}/a?x=1\n  body: json\n  auth: bearer\n}\n\nparams:query {\n  x: 1\n  ~y: 2\n}\n\nheaders {\n  Accept: application/json\n}\n\nauth:bearer {\n  token: {{t}}\n}\n\nbody:json {\n  {\n    \"a\": 1\n  }\n}\n\nvars:post-response {\n  id: res.body.id\n}\n\nassert {\n  res.status: eq 200\n}\n\ndocs {\n  Notes\n}\n",
        "vars {\n  host: example.com\n}\nvars:secret [\n  token\n]\n",
        "meta {\n  name: F\n}\n\nheaders {\n  X: 1\n}\n",
    ]
    static let curlSeeds = [
        #"curl 'https://api.example.com/x?a=1' -X POST -H 'Content-Type: application/json' --data-raw '{"a":1}' --compressed"#,
        #"curl -u user:pass -F "file=@/tmp/a.txt" -F name=x "https://e.example""#,
        "curl https://e.example -H $'X-Tab:\\t1' --cookie 'a=b' -A agent -L -k",
    ]
    static let postmanSeeds = [
        #"{"info":{"name":"S","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},"item":[{"name":"F","item":[{"name":"R","request":{"method":"POST","url":{"raw":"https://e/x?a=1"},"header":[{"key":"A","value":"b"}],"body":{"mode":"urlencoded","urlencoded":[{"key":"k","value":"v"}]}}}]}]}"#
    ]
    static let jsonPathSeeds = ["$.a.b[0]", "$..id", "$['x']['y z']", "$.items[*].name", "$.a[-1]", "$[0:2]"]
    static let graphQLSeeds = [
        "query Q($id: ID!) { user(id: $id) { name ...F @include(if: true) } } fragment F on User { email }",
        "mutation { add(input: {a: [1, 2.5, \"s\", \"\"\"block\"\"\", ENUM, null]}) { id } }",
    ]
    static let templateSeeds = ["https://{{host}}/a/{{ id }}?x={{$randomInt}}", "{{a}}{{b}}}}{{", "{{{{nested}}}}"]
    static let cookieSeeds = [
        "session=abc; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=3600",
        "a=b; Domain=.example.com; Expires=Wed, 21 Oct 2037 07:28:00 GMT", "=; ;;; Path",
    ]

    enum Target: String, CaseIterable, Sendable {
        case json, yaml, bru, bruEnvironment, curl, openAPI, postman, jsonPath, graphQL, templates, query, cookies
        case bodyDecoding, sharedURL, httpMethod
    }

    @Test(arguments: Target.allCases)
    func parserSurvivesHostileInput(target: Target) throws {
        // Stable seed per target (hashValue is randomized per process).
        let index = UInt64(Target.allCases.firstIndex(of: target) ?? 0)
        var mutator = Mutator(generator: SeededGenerator(seed: 0x5EED_0000 + index))
        let started = ContinuousClock.now
        var accepted = 0
        for _ in 0..<Self.iterations where try run(target, &mutator) {
            accepted += 1
        }
        #expect(ContinuousClock.now - started < .seconds(60), "\(target) is too slow on hostile input")
        // The mutations must keep a meaningful share of inputs valid, or the deeper code paths go untested.
        if let minimum = Self.minimumAccepted[target] {
            #expect(accepted >= minimum, "\(target): only \(accepted) of \(Self.iterations) inputs were accepted")
        }
    }

    /// Targets where some mutated inputs must still parse (the rest have no notion of "valid").
    static let minimumAccepted: [Target: Int] = [
        .json: 50, .yaml: 100, .bru: 50, .curl: 100, .jsonPath: 100, .graphQL: 100, .postman: 20,
    ]

    /// Returns whether the input was accepted (parsed without error).
    @discardableResult
    private func run(_ target: Target, _ mutator: inout Mutator) throws -> Bool {
        switch target {
        case .json:
            let text = mutator.input(from: Self.jsonSeeds)
            guard let value = try? JSONParser().parse(text) else { return false }
            // Invariant: whatever parses round-trips through the serializer.
            let again = try JSONParser().parse(JSONSerializer.string(from: value, style: .compact))
            #expect(again.isSemanticallyEqual(to: value))
            return true
        case .yaml:
            return (try? YAMLParser().parse(mutator.input(from: Self.yamlSeeds))) != nil
        case .bru:
            guard let (request, _) = try? BruRequestCodec.decode(mutator.input(from: Self.bruSeeds)) else {
                return false
            }
            // Invariant: a decoded request re-encodes to a file that decodes to the same request.
            let decodedAgain = try BruRequestCodec.decode(try BruRequestCodec.encode(request)).request
            #expect(decodedAgain.hasSameContent(as: request))
            return true
        case .bruEnvironment:
            let environment = try? BruEnvironmentCodec.decode(
                mutator.input(from: Self.bruSeeds), name: "E", environmentKey: "e")
            _ = try? BruFolderCodec.decode(mutator.input(from: Self.bruSeeds))
            return environment != nil
        case .curl:
            let text = mutator.input(from: Self.curlSeeds)
            _ = try? CurlParser.parse(text)
            guard let words = try? ShellWords.split(text) else { return false }
            // Invariant: quoting each word and splitting again gives the same words.
            #expect(try ShellWords.split(words.map(ShellWords.quote).joined(separator: " ")) == words)
            return true
        case .openAPI:
            return
                (try? OpenAPIImporter.importDocument(Data(mutator.input(from: Self.yamlSeeds + Self.jsonSeeds).utf8)))
                != nil
        case .postman:
            return (try? PostmanImporter.importDocument(Data(mutator.input(from: Self.postmanSeeds).utf8))) != nil
        case .jsonPath:
            let document = try JSONParser().parse(Self.jsonSeeds[0])
            guard let path = try? JSONPath(mutator.input(from: Self.jsonPathSeeds)) else { return false }
            _ = path.evaluate(document)
            return true
        case .graphQL:
            let source = mutator.input(from: Self.graphQLSeeds)
            _ = GraphQLValidator.diagnostics(for: source)
            return (try? GraphQLLexer.tokenize(source)) != nil
        case .templates:
            let text = mutator.input(from: Self.templateSeeds)
            _ = Interpolator.tokens(in: text)
            _ = Interpolator().interpolate(
                text, in: VariableContext(scopes: [VariableScope(kind: .global, values: ["host": .plain("h")])]))
            return true
        case .query:
            let text = mutator.input(from: Self.templateSeeds)
            let rows = QueryParameters.parse(fromURL: text)
            _ = QueryParameters.url(text, replacingQueryWith: rows)
            return true
        case .cookies:
            var jar = CookieJar()
            let url = try #require(URL(string: "https://api.example.com/a/b"))
            jar.store(
                setCookieHeaders: [mutator.input(from: Self.cookieSeeds)], from: url,
                now: Date(timeIntervalSince1970: 1_800_000_000))
            return jar.headerValue(for: url, now: Date(timeIntervalSince1970: 1_800_000_000)) != nil
        case .bodyDecoding:
            let data = Data(mutator.input(from: Self.jsonSeeds + Self.yamlSeeds).utf8)
            _ = BodyDecoder.decode(data, contentType: "text/plain; charset=\(mutator.input(from: ["utf-8", "latin1"]))")
            _ = ResponseContentKind.classify(contentType: nil, prefix: data)
            return true
        case .sharedURL:
            return SharedURL.url(from: mutator.input(from: Self.curlSeeds + Self.templateSeeds)) != nil
        case .httpMethod:
            let text = mutator.input(from: ["GET", "PURGE", "CUSTOM@METHOD"])
            if let method = HTTPMethod(rawValue: text) { #expect(method.isValidForSending) }
            return HTTPMethod(lenientBruValue: text) != nil
        }
    }
}
