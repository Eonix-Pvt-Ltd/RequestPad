import Foundation
import Testing

@testable import RPCore

@Suite("JSONPath")
struct JSONPathTests {
    let document: JSONValue
    init() throws {
        document = try JSONParser().parse(
            #"""
            {"store":{"book":[{"title":"A","price":8,"tags":["x"]},{"title":"B","price":12},{"title":"C"}],
             "bicycle":{"color":"red","price":20}},"key with space":1,"it's":2,"list":[0,1,2,3,4]}
            """#)
    }

    func values(_ path: String) throws -> [JSONValue] {
        try JSONPath(path).evaluate(document).map(\.value)
    }

    @Test(arguments: [
        ("$.store.book[0].title", [JSONValue.string("A")]),
        ("store.book[1].title", [.string("B")]),
        ("$.store.book[-1].title", [.string("C")]),
        ("$.store.book[*].title", [.string("A"), .string("B"), .string("C")]),
        ("$..price", [.number(8), .number(12), .number(20)]),
        ("$.store.book[0,2].title", [.string("A"), .string("C")]),
        ("$['key with space']", [.number(1)]),
        ("$[\"it's\"]", [.number(2)]),
        ("$['it\\'s']", [.number(2)]),
        ("$.list[1:3]", [.number(1), .number(2)]),
        ("$.list[:2]", [.number(0), .number(1)]),
        ("$.list[-2:]", [.number(3), .number(4)]),
        ("$.list[3:1]", []),
        ("$.store.bicycle.*", [.string("red"), .number(20)]),
        ("$.missing", []),
        ("$.store.book[9]", []),
        ("$.list.title", []),
        ("[\"list\"][0]", [.number(0)]),
        ("$..book[1].title", [.string("B")]),
        (
            "$..[0]",
            [
                .object([
                    JSONMember("title", .string("A")), JSONMember("price", .number(8)),
                    JSONMember("tags", .array([.string("x")])),
                ]), .string("x"), .number(0),
            ]
        ),
        ("$.store.book[ 0 , 1 ].price", [.number(8), .number(12)]),
    ])
    func evaluates(path: String, expected: [JSONValue]) throws {
        #expect(try values(path) == expected)
    }

    @Test func rootAndRecursiveWildcard() throws {
        #expect(try values("$") == [document])
        #expect(try values("$..*").count == 23)
    }

    @Test func locationsAreReported() throws {
        let matches = try JSONPath("$..title").evaluate(document)
        #expect(
            matches.map { JSONPath.format($0.location) } == [
                "$.store.book[0].title", "$.store.book[1].title", "$.store.book[2].title",
            ])
        #expect(JSONPath.format([.key("key with space"), .key("it's")]) == "$['key with space']['it\\'s']")
    }

    @Test(arguments: ["", "$.", "$[", "$[?(@.a)]", "$.a[1:2:3]", "$x", "$['a'", "$[abc]", "$.[0]", "$['unterminated]"])
    func invalidPaths(path: String) {
        #expect(throws: CoreError.self) { try JSONPath(path) }
    }

    @Test func overlyLongPathRejected() {
        #expect(throws: CoreError.self) { try JSONPath("$." + String(repeating: "a", count: 5000)) }
    }

    @Test func simpleSegments() throws {
        #expect(try JSONPath("$.a[0].b").simpleSegments == [.key("a"), .index(0), .key("b")])
        #expect(try JSONPath("$.a[*]").simpleSegments == nil)
        #expect(try JSONPath("$..a").simpleSegments == nil)
        #expect(try JSONPath("$.a[-1]").simpleSegments == nil)
        #expect(try JSONPath("$").simpleSegments == [])
        #expect(try JSONPath("$.a").description == "$.a")
    }

    @Test func firstValue() throws {
        #expect(try JSONPath("$.list[4]").firstValue(in: document) == .number(4))
        #expect(try JSONPath("$.nope").firstValue(in: document) == nil)
    }

    @Test func matchCountIsCapped() throws {
        let big = JSONValue.array(Array(repeating: .number(1), count: JSONPath.maximumMatches + 50))
        #expect(try JSONPath("$[*]").evaluate(big).count == JSONPath.maximumMatches)
        #expect(try JSONPath("$..*").evaluate(big).count == JSONPath.maximumMatches)
    }
}
