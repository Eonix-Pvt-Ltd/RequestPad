import Foundation
import Testing

@testable import RPCore

@Suite("YAMLParser")
struct YAMLParserTests {
    func yaml(_ text: String) throws -> JSONValue { try YAMLParser().parse(text) }
    func json(_ text: String) throws -> JSONValue { try JSONParser().parse(text) }

    @Test(
        arguments: [
            (
                "a: 1\nb: two\nc: true\nd: null\ne: ~\nf:\ng: 1.5\nh: -0.25e3\ni: 0x1F\nj: 0o17\nk: +7\nl: .5\nm: .inf\nn: 007",
                #"{"a":1,"b":"two","c":true,"d":null,"e":null,"f":null,"g":1.5,"h":-0.25e3,"i":31,"j":15,"k":7,"l":0.5,"m":".inf","n":7}"#
            ),
            (
                "- a\n- 2\n-\n  - nested\n- key: v\n  other: w\n- - x\n  - y",
                #"["a",2,["nested"],{"key":"v","other":"w"},["x","y"]]"#
            ),
            (
                "root:\n  child:\n    leaf: 1\n  list:\n  - a\n  - b\nnext: x",
                #"{"root":{"child":{"leaf":1},"list":["a","b"]},"next":"x"}"#
            ),
            (
                "'quoted: key': 1\n\"double\\tkey\": 2\nurl: http://x.com/a#frag\nhash: a#b # comment\n",
                #"{"quoted: key":1,"double\tkey":2,"url":"http://x.com/a#frag","hash":"a#b"}"#
            ),
            (
                "s: 'it''s'\nd: \"esc \\\" \\\\ \\n \\u00e9 \\x41 \\/\"\nplain: it's # note",
                #"{"s":"it's","d":"esc \" \\ \n é A /","plain":"it's"}"#
            ),
            (
                "flow: [1, 'two', \"three\", {a: b, c: [x, y]}, ]\nmap: {k: v, empty: , n: 3}",
                #"{"flow":[1,"two","three",{"a":"b","c":["x","y"]}],"map":{"k":"v","empty":null,"n":3}}"#
            ),
            ("multi: [\n  a,\n  b # comment\n]\nnext: 1", #"{"multi":["a","b"],"next":1}"#),
            (
                "plain: first line\n  second line\n\n  third after blank\nnext: 1",
                #"{"plain":"first line second line\nthird after blank","next":1}"#
            ),
            (
                "q: \"folded\n  across\n\n  lines\"\ns: 'single\n  folded'",
                #"{"q":"folded across\nlines","s":"single folded"}"#
            ),
            ("e: \"no \\\n  space\"", #"{"e":"no space"}"#),
            ("---\n# comment\nkey: value\n...\nignored: true", #"{"key":"value"}"#),
            ("--- inline", #""inline""#),
            ("%YAML 1.2\n---\na: 1", #"{"a":1}"#),
            ("", "null"),
            ("# only comment\n", "null"),
            ("\u{FEFF}a: 1\r\nb: 2\r\n", #"{"a":1,"b":2}"#),
            ("a: 1\na: 2", #"{"a":2}"#),
            ("200:\n  description: OK\n'404': x", #"{"200":{"description":"OK"},"404":"x"}"#),
            ("tags: [a, 'b, c', \"d]\"]", #"{"tags":["a","b, c","d]"]}"#),
            ("? ", nil),
        ] as [(String, String?)])
    func parses(input: String, expectedJSON: String?) throws {
        guard let expectedJSON else {
            #expect(throws: CoreError.self) { try yaml(input) }
            return
        }
        let actual = try yaml(input)
        let expected = try json(expectedJSON)
        #expect(actual.isSemanticallyEqual(to: expected), "\(JSONSerializer.string(from: actual, style: .compact))")
    }

    @Test func blockScalars() throws {
        let text = """
            literal: |
              line 1
                indented
              line 3

            folded: >
              folded
              text

              new paragraph
                kept indented
              back
            strip: |-
              no newline
            keep: |+
              keep

            explicit: |2
                two extra
            empty: |
            last: end
            """
        let value = try yaml(text)
        #expect(value["literal"] == .string("line 1\n  indented\nline 3\n"))
        #expect(value["folded"] == .string("folded text\nnew paragraph\n  kept indented\nback\n"))
        #expect(value["strip"] == .string("no newline"))
        #expect(value["keep"] == .string("keep\n\n"))
        #expect(value["explicit"] == .string("  two extra\n"))
        #expect(value["empty"] == .string(""))
        #expect(value["last"] == .string("end"))
    }

    @Test func anchorsAliasesAndMerge() throws {
        let text = """
            base: &base
              type: object
              required: [id]
            name: &n Ann
            derived:
              <<: *base
              type: array
            list:
              - *n
              - &item {x: 1}
              - *item
            multi:
              <<: [*base, {extra: true}]
            """
        let value = try yaml(text)
        #expect(value["derived"] == (try json(#"{"type":"array","required":["id"]}"#)))
        #expect(value["list"] == (try json(#"["Ann",{"x":1},{"x":1}]"#)))
        #expect(value["multi"]?["extra"] == .bool(true))
        #expect(value["multi"]?["type"] == .string("object"))
    }

    @Test func multiWordPlainScalarsInFlowAndAnchorsInFlow() throws {
        let value = try yaml("a: {b: 1 c}\nl: [&x one, *x, &m {k: v}, *m]")
        #expect(value["a"]?["b"] == .string("1 c"))
        #expect(value["l"] == (try json(#"["one","one",{"k":"v"},{"k":"v"}]"#)))
    }

    @Test func tags() throws {
        let value = try yaml(
            "a: !!str 123\nb: !!int '42'\nc: !!bool 'true'\nd: !!null x\ne: !!float 1\nf: !!map {k: v}")
        #expect(value["a"] == .string("123"))
        #expect(value["b"] == .number("42"))
        #expect(value["c"] == .bool(true))
        #expect(value["d"] == .null)
        #expect(value["e"] == .number("1"))
        #expect(value["f"]?["k"] == .string("v"))
        #expect(throws: CoreError.self) { try yaml("a: !custom x") }
        #expect(throws: CoreError.self) { try yaml("a: !!int abc") }
    }

    @Test func aliasExpansionIsCapped() {
        var text = "a: &a [x]\n"
        for index in 0...YAMLParser.maximumAliasExpansions { text += "k\(index): *a\n" }
        #expect(throws: CoreError.self) { try yaml(text) }
    }

    @Test(.timeLimit(.minutes(1)))
    func billionLaughsIsRejected() {
        let text = """
            a: &a ["lol","lol","lol","lol","lol","lol","lol","lol","lol"]
            b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
            c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
            d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
            e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
            f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
            g: &g [*f,*f,*f,*f,*f,*f,*f,*f,*f]
            h: &h [*g,*g,*g,*g,*g,*g,*g,*g,*g]
            """
        let started = ContinuousClock.now
        let result = Result { try yaml(text) }
        #expect((try? result.get()) == nil, "must be rejected")
        #expect(ContinuousClock.now - started < .seconds(2))
        let block = """
            a: &a
              - lol
              - lol
            b: &b
              - *a
              - *a
            """
        #expect(throws: Never.self) { try yaml(block) }
    }

    @Test(arguments: [
        ("a: 1\n  b: 2", 2), ("a:\n\t- x", 2), ("- a\nb: 1", 2), ("a: [1, 2", 1), ("a: \"open", 1), ("a: *missing", 1),
        ("key: 'x' trailing", 1), ("a: {b: 1] }", 1), ("a: |x\n  y", 1), ("%TAG ! tag:x\n---\na: 1", 1), ("a: & x", 1),
        ("a: \"\\q\"", 1), ("a: [x] y", 1),
    ])
    func errorsReportLines(input: String, line: Int) {
        #expect {
            try yaml(input)
        } throws: { error in
            guard case .yamlSyntax(let position, _) = error as? CoreError else { return false }
            return position.line == line
        }
    }

    @Test func depthAndSizeLimits() {
        var deep = ""
        for level in 0..<70 { deep += String(repeating: " ", count: level * 2) + "k:\n" }
        #expect(throws: CoreError.nestingTooDeep(limit: 64)) { try yaml(deep) }
        #expect(throws: CoreError.inputTooLarge(limitBytes: 3)) { try YAMLParser(maximumBytes: 3).parse("a: 1") }
        let flowDeep = String(repeating: "[", count: 80) + String(repeating: "]", count: 80)
        #expect(throws: CoreError.nestingTooDeep(limit: 64)) { try yaml(flowDeep) }
    }

    @Test func openAPIShapedDocument() throws {
        let text = try FixtureLoader.text("openapi/petstore.yaml")
        let value = try yaml(text)
        #expect(value["openapi"] == .string("3.0.3"))
        #expect(value["paths"]?["/pets/{petId}"]?["get"]?["operationId"] == .string("showPetById"))
        #expect(value["info"]?["description"]?.stringValue?.hasPrefix("A sample API") == true)
    }
}
