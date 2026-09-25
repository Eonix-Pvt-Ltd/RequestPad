import Foundation
import Testing

@testable import RPCore

@Suite("GraphQL")
struct GraphQLTests {
    let schema: GraphQLSchema
    init() throws {
        schema = try GraphQLSchema.fromIntrospection(
            try JSONParser().parse(try FixtureLoader.data("graphql/introspection.json")))
    }

    @Test func lexesAllTokenKinds() throws {
        let tokens = try GraphQLLexer.tokenize(
            "query Q($id: ID! = 5, $f: [Float] = -1.5e3) @x { a: f(s: \"s\\\"q\", b: \"\"\"blk\n\\\"\"\"\"\"\") ...on T { g } } # c\r\n"
        )
        #expect(tokens.map(\.text).prefix(8) == ["query", "Q", "(", "$", "id", ":", "ID", "!"])
        #expect(tokens.contains { $0.kind == .float && $0.text == "-1.5e3" })
        #expect(tokens.contains { $0.kind == .int && $0.text == "5" })
        #expect(tokens.contains { $0.kind == .string && $0.text == "\"s\\\"q\"" })
        #expect(tokens.contains { $0.kind == .blockString })
        #expect(tokens.contains { $0.kind == .punctuator("...") })
        let second = try GraphQLLexer.tokenize("a\n  b")
        #expect(second[1].position == TextPosition(line: 2, column: 3))
        #expect(second[1].offset == 4)
    }

    @Test(arguments: ["\"open", "\"\"\"open", "a . b", "a ^", "-", "1e"])
    func lexerErrors(source: String) {
        #expect(throws: CoreError.self) { try GraphQLLexer.tokenize(source) }
    }

    @Test(arguments: [
        "{ user(id: 1) { id name } }",
        "query Q($id: ID!) { user(id: $id) { ...F @include(if: true) } } fragment F on User { name }",
        "mutation { createUser(input: {name: \"a\", tags: [1, 2.5, ENUM, null, true]}) { id } }",
        "subscription S @d { events { ... on User { id } ... @skip(if: false) { name } } }",
        "query($a: [Int!]! = [1] @dir) { a }", "{ a { b { c } } } { d }",
    ])
    func validDocuments(source: String) {
        #expect(GraphQLValidator.diagnostics(for: source).isEmpty, "\(GraphQLValidator.diagnostics(for: source))")
    }

    @Test(arguments: [
        ("", 1, 1, "empty"), ("{ }", 1, 3, "empty"), ("{ user(id: ) { id } }", 1, 12, "value"),
        ("{ user { id }", 1, 14, "Missing"),
        ("query ($a: Int = $b) { a }", 1, 18, "Variables"), ("frag F on X { a }", 1, 1, "Expected"),
        ("fragment on on X { a }", 1, 13, "on"),
        ("fragment F X { a }", 1, 12, "on"), ("{ a(x: 1 }", 1, 10, "name"), ("{ a(b: [1 }", 1, 11, "value"),
        ("{\n  a ! }", 2, 5, "name"),
        ("{ a(b: {c 1}) }", 1, 11, "“:”"), ("{ a() }", 1, 5, "empty"), ("\"x", 1, 1, "string"),
    ])
    func invalidDocuments(source: String, line: Int, column: Int, hint: String) {
        let diagnostics = GraphQLValidator.diagnostics(for: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.position == TextPosition(line: line, column: column), "\(diagnostics)")
        #expect(diagnostics.first?.message.contains(hint) == true, "\(diagnostics)")
    }

    @Test func deepNestingIsReported() {
        let source = String(repeating: "{ a ", count: 70) + String(repeating: "}", count: 70)
        #expect(!GraphQLValidator.diagnostics(for: source).isEmpty)
    }

    @Test func schemaFromIntrospection() throws {
        #expect(schema.queryType == "Query")
        #expect(schema.mutationType == "Mutation")
        #expect(schema.subscriptionType == nil)
        #expect(schema.types["Future"] == nil)
        #expect(schema.field("users", of: "Query")?.type.description == "[User!]!")
        #expect(schema.field("users", of: "Query")?.type.namedType == "User")
        #expect(schema.types["Role"]?.enumValues == ["ADMIN", "DEV"])
        #expect(schema.types["NewUser"]?.inputFields.first?.type == .nonNull(.named("String")))
        #expect(schema.types["Node"]?.possibleTypes == ["User"])
        let bare = try GraphQLSchema.fromIntrospection(
            try JSONParser().parse(#"{"__schema":{"types":[{"kind":"SCALAR","name":"X"}]}}"#))
        #expect(bare.queryType == nil)
        let decoded = try JSONDecoder().decode(GraphQLSchema.self, from: JSONEncoder().encode(schema))
        #expect(decoded == schema)
    }

    @Test(arguments: [
        #"{"errors":[{"message":"Introspection is disabled"}]}"#, #"{"data":{}}"#, #"{"__schema":{"types":[]}}"#,
        #"{"__schema":{"types":[{"kind":"OBJECT","name":"Q","fields":[{"name":"f","args":[],"type":{"kind":"LIST","ofType":null}}]}]}}"#,
        #"{"__schema":{"types":[{"kind":"OBJECT","name":"Q","fields":[{"name":"f","args":[],"type":{"kind":"OBJECT"}}]}]}}"#,
    ])
    func invalidIntrospection(json: String) throws {
        let value = try JSONParser().parse(json)
        #expect(throws: CoreError.self) { try GraphQLSchema.fromIntrospection(value) }
    }

    func labels(_ source: String, cursorMarker: String = "|") -> [String] {
        let cursor = source.unicodeScalars.distance(
            from: source.unicodeScalars.startIndex,
            to: source.range(of: cursorMarker)?.lowerBound.samePosition(in: source.unicodeScalars)
                ?? source.unicodeScalars.endIndex)
        let text = source.replacingOccurrences(of: cursorMarker, with: "")
        return GraphQLCompleter.completions(in: text, cursorOffset: cursor, schema: schema).map(\.label)
    }

    @Test func completesFieldsArgumentsTypesAndKeywords() {
        #expect(labels("|") == ["query", "mutation", "subscription", "fragment"])
        #expect(labels("mu|") == ["mutation"])
        #expect(labels("{ |}") == ["node", "user", "users", "__typename"])
        #expect(labels("query { us| }") == ["user", "users"])
        #expect(labels("{ user(id: 1) { | } }") == ["friends", "id", "name", "role", "legacyName", "__typename"])
        #expect(labels("{ me: user(id: 1) { friends(first: 2) { na| } } }") == ["name"])
        #expect(labels("{ users(|) }") == ["first", "role", "active"])
        #expect(labels("{ users(first: 1, r|) }") == ["role"])
        #expect(labels("{ users(role: |) }") == ["ADMIN", "DEV"])
        #expect(labels("{ users(active: |) }") == ["true", "false"])
        #expect(labels("{ users(first: |) }").isEmpty)
        #expect(labels("mutation { |") == ["createUser", "__typename"])
        #expect(labels("{ node(id: 1) { |") == ["id", "__typename", "... on User"])
        #expect(labels("{ node(id: 1) { ... on |") == ["Mutation", "Node", "Query", "User"])
        #expect(labels("{ node(id: 1) { ... on User { rol|") == ["role"])
        #expect(labels("fragment F on User { |") == ["friends", "id", "name", "role", "legacyName", "__typename"])
        #expect(labels("{ unknown { |").isEmpty)
        #expect(labels("{ user(id: \"unterminated |").isEmpty)
        #expect(labels("{ user(id: 1) { id } } |") == ["query", "mutation", "subscription", "fragment"])
    }

    @Test func completionDetailsAndCursorClamping() {
        let completions = GraphQLCompleter.completions(in: "{ ", cursorOffset: 99, schema: schema)
        #expect(completions.first { $0.label == "users" }?.detail == "[User!]!")
        #expect(completions.first { $0.label == "users" }?.kind == .field)
        let deprecated = GraphQLCompleter.completions(in: "{ user(id: 1) { ", cursorOffset: 16, schema: schema)
        #expect(deprecated.first { $0.label == "legacyName" }?.isDeprecated == true)
        #expect(GraphQLCompleter.completions(in: "", cursorOffset: -5, schema: schema).count == 4)
    }

    @Test func introspectionQueryIsValid() {
        #expect(GraphQLValidator.diagnostics(for: GraphQLSchema.introspectionQuery).isEmpty)
    }
}
