import Foundation
import Testing

@testable import RPCore

@Suite("JSONParser")
struct JSONParserTests {
    let parser = JSONParser()

    @Test func parsesAllValueKindsPreservingOrderAndNumbers() throws {
        let value = try parser.parse(#"{"z":1,"a":[true,false,null],"n":-12.50e+3,"s":"x\"y\\z\/\n","o":{}}"#)
        guard case .object(let members) = value else {
            Issue.record("Expected object")
            return
        }
        #expect(members.map(\.key) == ["z", "a", "n", "s", "o"])
        #expect(value["n"] == .number("-12.50e+3"))
        #expect(value["a"] == .array([.bool(true), .bool(false), .null]))
        #expect(value["s"] == .string("x\"y\\z/\n"))
        #expect(value["o"] == .object([]))
    }

    @Test(arguments: [
        (#""\u00e9""#, "é"), (#""\ud83d\ude00""#, "😀"), (#""\ud83d""#, "\u{FFFD}"), (#""\ude00""#, "\u{FFFD}"),
        (#""\ud83d\u0041""#, "\u{FFFD}A"), (#""\u0000""#, "\u{0}"),
    ])
    func unicodeEscapes(input: String, expected: String) throws {
        #expect(try parser.parse(input) == .string(expected))
    }

    @Test func skipsByteOrderMark() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("[1]".utf8))
        #expect(try parser.parse(data) == .array([.number("1")]))
    }

    @Test func invalidUTF8InStringsBecomesReplacementCharacter() throws {
        let data = Data([0x22, 0xFF, 0x41, 0x22])
        #expect(try parser.parse(data) == .string("\u{FFFD}A"))
    }

    @Test(arguments: [
        ("", 1, 1), ("[1,]", 1, 4), ("{\"a\" 1}", 1, 6), ("[01]", 1, 2), ("\"abc", 1, 1), ("tru", 1, 1),
        ("{\"a\":1}\n x", 2, 2), ("[1.]", 1, 4), ("[1e]", 1, 4), ("[\"a\nb\"]", 1, 4), ("{1:2}", 1, 2),
        ("[\"\\x\"]", 1, 3), ("[1 2]", 1, 4), ("{\"a\":1", 1, 7), ("-", 1, 1), ("[\"\\u12\"]", 1, 7),
    ])
    func reportsErrorPositions(input: String, line: Int, column: Int) {
        #expect {
            try parser.parse(input)
        } throws: { error in
            guard case .jsonSyntax(let position, _) = error as? CoreError else { return false }
            return position == TextPosition(line: line, column: column)
        }
    }

    @Test func enforcesDepthLimit() {
        let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        #expect(throws: CoreError.nestingTooDeep(limit: 256)) { try parser.parse(deep) }
        let ok = String(repeating: "[", count: 256) + String(repeating: "]", count: 256)
        #expect(throws: Never.self) { try parser.parse(ok) }
    }

    @Test func enforcesSizeLimit() {
        let small = JSONParser(maximumBytes: 4)
        #expect(throws: CoreError.inputTooLarge(limitBytes: 4)) { try small.parse("[1,2]") }
    }

    @Test func accessors() throws {
        let value = try parser.parse(#"{"a":[10,"x"],"b":true,"a2":1.5}"#)
        #expect(value["a"]?[0]?.intValue == 10)
        #expect(value["a"]?[1]?.stringValue == "x")
        #expect(value["a"]?[5] == nil)
        #expect(value["b"]?.boolValue == true)
        #expect(value["a2"]?.decimalValue == Decimal(string: "1.5"))
        #expect(value["missing"] == nil)
        #expect(JSONValue.null["x"] == nil)
        #expect(value["a"]?.arrayValue?.count == 2)
        #expect(value.objectValue?.count == 3)
        #expect(JSONValue.string("s").intValue == nil)
        #expect(
            [JSONValue.null, .bool(true), .number(1), .string(""), .array([]), .object([])].map(\.typeName)
                == ["null", "boolean", "number", "string", "array", "object"])
    }

    @Test func duplicateKeysLastWins() throws {
        #expect(try parser.parse(#"{"a":1,"a":2}"#)["a"] == .number("2"))
    }

    @Test func semanticEquality() throws {
        let lhs = try parser.parse(#"{"a":1,"b":[1.0,{"c":null}]}"#)
        let rhs = try parser.parse(#"{"b":[1,{"c":null}],"a":1.00}"#)
        #expect(lhs.isSemanticallyEqual(to: rhs))
        #expect(!lhs.isSemanticallyEqual(to: try parser.parse(#"{"a":2,"b":[1,{"c":null}]}"#)))
        #expect(!JSONValue.array([.number(1)]).isSemanticallyEqual(to: .array([])))
        #expect(!JSONValue.object([JSONMember("a", .null)]).isSemanticallyEqual(to: .object([JSONMember("b", .null)])))
    }
}

@Suite("JSONSerializer")
struct JSONSerializerTests {
    @Test func prettyAndCompactRoundTrip() throws {
        let source = #"{"a":[1,2.50,{"b":null}],"c":"q\"\n\t\u0001é","d":{},"e":[],"f":false}"#
        let value = try JSONParser().parse(source)
        let compact = JSONSerializer.string(from: value, style: .compact)
        #expect(compact == #"{"a":[1,2.50,{"b":null}],"c":"q\"\n\t\u0001é","d":{},"e":[],"f":false}"#)
        let pretty = JSONSerializer.string(from: value)
        #expect(pretty.contains("\n  \"a\": [\n    1,"))
        #expect(try JSONParser().parse(pretty) == value)
    }

    @Test func escapesControlCharacters() {
        #expect(JSONSerializer.quoted("\u{08}\u{0C}\r\\") == #""\b\f\r\\""#)
    }
}
