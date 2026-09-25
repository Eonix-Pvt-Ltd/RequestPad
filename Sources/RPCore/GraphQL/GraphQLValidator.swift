import Foundation

/// A syntax problem in a GraphQL document, shown inline in the editor (P04.3).
public struct GraphQLDiagnostic: Hashable, Sendable {
    public var position: TextPosition
    public var message: String
}

/// Recursive-descent syntax check for GraphQL executable documents (operations and fragments). Reports the first
/// syntax error; it does not validate against a schema.
public enum GraphQLValidator {
    public static func diagnostics(for source: String) -> [GraphQLDiagnostic] {
        do {
            var parser = Parser(tokens: try GraphQLLexer.tokenize(source))
            try parser.parseDocument()
            return []
        } catch {
            return [diagnostic(from: error)]
        }
    }

    private static func diagnostic(from error: CoreError) -> GraphQLDiagnostic {
        switch error {
        case .invalidDocument(let path, let reason):
            let numbers = path.replacingOccurrences(of: "GraphQL ", with: "").split(separator: ":").compactMap {
                Int($0)
            }
            let position =
                numbers.count == 2
                ? TextPosition(line: numbers[0], column: numbers[1]) : TextPosition(line: 1, column: 1)
            return GraphQLDiagnostic(position: position, message: reason)
        default:
            return GraphQLDiagnostic(
                position: TextPosition(line: 1, column: 1), message: error.errorDescription ?? "Invalid GraphQL")
        }
    }

    struct Parser {
        let tokens: [GraphQLToken]
        var index = 0
        var depth = 0
        static let maximumDepth = 64

        var current: GraphQLToken? { index < tokens.count ? tokens[index] : nil }

        func error(_ message: String) -> CoreError {
            let position =
                current?.position ?? tokens.last.map {
                    TextPosition(line: $0.position.line, column: $0.position.column + $0.text.count)
                }
                ?? TextPosition(line: 1, column: 1)
            return .invalidDocument(path: "GraphQL \(position)", reason: message)
        }

        func isPunctuator(_ text: String) -> Bool { current?.kind == .punctuator(text) }
        func isName(_ text: String? = nil) -> Bool { current?.kind == .name && (text == nil || current?.text == text) }

        mutating func expect(_ punctuator: String) throws(CoreError) {
            guard isPunctuator(punctuator) else {
                throw error(
                    current.map { "Expected “\(punctuator)” but found “\($0.text)”." }
                        ?? "Expected “\(punctuator)” at the end.")
            }
            index += 1
        }

        mutating func expectName() throws(CoreError) -> String {
            guard let token = current, token.kind == .name else {
                throw error(current.map { "Expected a name but found “\($0.text)”." } ?? "Expected a name at the end.")
            }
            index += 1
            return token.text
        }

        mutating func parseDocument() throws(CoreError) {
            guard current != nil else { throw error("The query is empty.") }
            while current != nil {
                if isPunctuator("{") {
                    try parseSelectionSet()
                } else if isName("query") || isName("mutation") || isName("subscription") {
                    index += 1
                    if isName() { index += 1 }
                    if isPunctuator("(") { try parseVariableDefinitions() }
                    try parseDirectives()
                    try parseSelectionSet()
                } else if isName("fragment") {
                    index += 1
                    let name = try expectName()
                    guard name != "on" else { throw error("A fragment can't be named “on”.") }
                    guard isName("on") else { throw error("Expected “on” after the fragment name.") }
                    index += 1
                    _ = try expectName()
                    try parseDirectives()
                    try parseSelectionSet()
                } else {
                    throw error(
                        "Expected “query”, “mutation”, “subscription”, “fragment” or “{” but found “\(current?.text ?? "")”."
                    )
                }
            }
        }

        mutating func parseVariableDefinitions() throws(CoreError) {
            try expect("(")
            repeat {
                try expect("$")
                _ = try expectName()
                try expect(":")
                try parseType()
                if isPunctuator("=") {
                    index += 1
                    try parseValue(isConstant: true)
                }
                try parseDirectives()
            } while !isPunctuator(")") && current != nil
            try expect(")")
        }

        mutating func parseType() throws(CoreError) {
            if isPunctuator("[") {
                index += 1
                try parseType()
                try expect("]")
            } else {
                _ = try expectName()
            }
            if isPunctuator("!") { index += 1 }
        }

        mutating func parseDirectives() throws(CoreError) {
            while isPunctuator("@") {
                index += 1
                _ = try expectName()
                if isPunctuator("(") { try parseArguments() }
            }
        }

        mutating func parseSelectionSet() throws(CoreError) {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maximumDepth else { throw .nestingTooDeep(limit: Self.maximumDepth) }
            try expect("{")
            guard !isPunctuator("}") else { throw error("A selection set can't be empty.") }
            while !isPunctuator("}") {
                guard current != nil else { throw error("Missing “}”.") }
                if isPunctuator("...") {
                    index += 1
                    if isName("on") {
                        index += 1
                        _ = try expectName()
                        try parseDirectives()
                        try parseSelectionSet()
                    } else if isName() {
                        index += 1
                        try parseDirectives()
                    } else {
                        try parseDirectives()
                        try parseSelectionSet()
                    }
                } else {
                    _ = try expectName()
                    if isPunctuator(":") {
                        index += 1
                        _ = try expectName()
                    }
                    if isPunctuator("(") { try parseArguments() }
                    try parseDirectives()
                    if isPunctuator("{") { try parseSelectionSet() }
                }
            }
            try expect("}")
        }

        mutating func parseArguments() throws(CoreError) {
            try expect("(")
            guard !isPunctuator(")") else { throw error("Arguments can't be empty.") }
            while !isPunctuator(")") {
                guard current != nil else { throw error("Missing “)”.") }
                _ = try expectName()
                try expect(":")
                try parseValue(isConstant: false)
            }
            try expect(")")
        }

        mutating func parseValue(isConstant: Bool) throws(CoreError) {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maximumDepth else { throw .nestingTooDeep(limit: Self.maximumDepth) }
            guard let token = current else { throw error("Expected a value at the end.") }
            switch token.kind {
            case .punctuator("$"):
                guard !isConstant else { throw error("Variables aren't allowed in default values.") }
                index += 1
                _ = try expectName()
            case .int, .float, .string, .blockString, .name:
                index += 1
            case .punctuator("["):
                index += 1
                while !isPunctuator("]") {
                    guard current != nil else { throw error("Missing “]”.") }
                    try parseValue(isConstant: isConstant)
                }
                index += 1
            case .punctuator("{"):
                index += 1
                while !isPunctuator("}") {
                    guard current != nil else { throw error("Missing “}”.") }
                    _ = try expectName()
                    try expect(":")
                    try parseValue(isConstant: isConstant)
                }
                index += 1
            default:
                throw error("Expected a value but found “\(token.text)”.")
            }
        }
    }
}
