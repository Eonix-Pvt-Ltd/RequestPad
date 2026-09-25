import Foundation

/// An autocomplete suggestion for the GraphQL editor (P04.3).
public struct GraphQLCompletion: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case field
        case argument
        case keyword
        case type
        case enumValue
    }

    public var label: String
    public var detail: String
    public var kind: Kind
    public var isDeprecated: Bool
}

/// Suggests fields, arguments, types and keywords at a cursor position using a schema.
public enum GraphQLCompleter {
    public static let maximumSuggestions = 200

    /// `cursorOffset` counts Unicode scalars from the start of `source`.
    public static func completions(in source: String, cursorOffset: Int, schema: GraphQLSchema) -> [GraphQLCompletion] {
        let scalars = Array(source.unicodeScalars)
        let cursor = min(max(cursorOffset, 0), scalars.count)
        var prefixStart = cursor
        while prefixStart > 0, GraphQLLexer.isNameContinue(scalars[prefixStart - 1]) { prefixStart -= 1 }
        let prefix = String(String.UnicodeScalarView(scalars[prefixStart..<cursor]))
        let before = String(String.UnicodeScalarView(scalars[..<prefixStart]))
        // Tokenize leniently: an unterminated string before the cursor means we are inside it; no suggestions.
        guard let tokens = try? GraphQLLexer.tokenize(before) else { return [] }
        let context = Context.analyze(tokens, schema: schema)
        let candidates = suggestions(for: context, schema: schema)
        let lowered = prefix.lowercased()
        return Array(
            candidates.filter { lowered.isEmpty || $0.label.lowercased().hasPrefix(lowered) }.prefix(maximumSuggestions)
        )
    }

    enum Position {
        case topLevel
        case selection(parentType: String?)
        case arguments(parentType: String?, field: String)
        case typeCondition
        case argumentValue(type: GraphQLSchema.TypeRef?)
    }

    struct Context {
        var position: Position

        static func analyze(_ tokens: [GraphQLToken], schema: GraphQLSchema) -> Context {
            var stack: [String?] = []
            var pendingType: String?
            var lastField: String?
            var lastFieldParent: String?
            var argumentsField: (parent: String?, field: String)?
            var lastArgumentName: String?
            var expectTypeCondition = false
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                switch token.kind {
                case .name where stack.isEmpty && argumentsField == nil:
                    switch token.text {
                    case "query": pendingType = schema.queryType
                    case "mutation": pendingType = schema.mutationType
                    case "subscription": pendingType = schema.subscriptionType
                    case "on": expectTypeCondition = true
                    default:
                        if expectTypeCondition {
                            pendingType = token.text
                            expectTypeCondition = false
                        }
                    }
                case .name where argumentsField != nil:
                    if index + 1 < tokens.count, tokens[index + 1].kind == .punctuator(":") {
                        lastArgumentName = token.text
                    }
                case .name:
                    if token.text == "on", index > 0, tokens[index - 1].kind == .punctuator("...") {
                        expectTypeCondition = true
                    } else if expectTypeCondition {
                        pendingType = token.text
                        expectTypeCondition = false
                    } else if index + 1 < tokens.count, tokens[index + 1].kind == .punctuator(":") {
                        // Alias: the field name follows the colon.
                    } else {
                        lastField = token.text
                        lastFieldParent = stack.last ?? nil
                    }
                case .punctuator("{"):
                    if argumentsField != nil { break }
                    if let type = pendingType {
                        stack.append(type)
                        pendingType = nil
                    } else if stack.isEmpty {
                        stack.append(schema.queryType)
                    } else if let field = lastField, let parent = lastFieldParent {
                        stack.append(schema.field(field, of: parent)?.type.namedType)
                    } else {
                        stack.append(nil)
                    }
                    lastField = nil
                case .punctuator("}"):
                    if argumentsField == nil, !stack.isEmpty { stack.removeLast() }
                    lastField = nil
                case .punctuator("("):
                    if let field = lastField { argumentsField = (lastFieldParent, field) }
                case .punctuator(")"):
                    argumentsField = nil
                    lastArgumentName = nil
                default:
                    break
                }
                index += 1
            }
            if expectTypeCondition { return Context(position: .typeCondition) }
            if let (parent, field) = argumentsField {
                if let last = tokens.last, last.kind == .punctuator(":"), let name = lastArgumentName, let parent {
                    let type = schema.field(field, of: parent)?.arguments.first { $0.name == name }?.type
                    return Context(position: .argumentValue(type: type))
                }
                return Context(position: .arguments(parentType: parent, field: field))
            }
            if stack.isEmpty { return Context(position: .topLevel) }
            return Context(position: .selection(parentType: stack.last ?? nil))
        }
    }

    static func suggestions(for context: Context, schema: GraphQLSchema) -> [GraphQLCompletion] {
        switch context.position {
        case .topLevel:
            return ["query", "mutation", "subscription", "fragment"].map {
                GraphQLCompletion(label: $0, detail: "keyword", kind: .keyword, isDeprecated: false)
            }
        case .selection(let parentType):
            guard let parentType, let type = schema.types[parentType] else { return [] }
            var result = type.fields.sorted {
                $0.isDeprecated == $1.isDeprecated ? $0.name < $1.name : !$0.isDeprecated
            }.map {
                GraphQLCompletion(
                    label: $0.name, detail: $0.type.description, kind: .field, isDeprecated: $0.isDeprecated)
            }
            result.append(GraphQLCompletion(label: "__typename", detail: "String!", kind: .field, isDeprecated: false))
            if type.kind == .interface || type.kind == .union {
                result.append(
                    contentsOf: type.possibleTypes.sorted().map {
                        GraphQLCompletion(label: "... on \($0)", detail: "fragment", kind: .type, isDeprecated: false)
                    })
            }
            return result
        case .arguments(let parentType, let field):
            guard let parentType, let definition = schema.field(field, of: parentType) else { return [] }
            return definition.arguments.map {
                GraphQLCompletion(label: $0.name, detail: $0.type.description, kind: .argument, isDeprecated: false)
            }
        case .typeCondition:
            return schema.types.values.filter {
                [.object, .interface, .union].contains($0.kind) && !$0.name.hasPrefix("__")
            }
            .map(\.name).sorted().map { GraphQLCompletion(label: $0, detail: "type", kind: .type, isDeprecated: false) }
        case .argumentValue(let type):
            guard let name = type?.namedType, let definition = schema.types[name] else { return [] }
            if definition.kind == .enumeration {
                return definition.enumValues.map {
                    GraphQLCompletion(label: $0, detail: name, kind: .enumValue, isDeprecated: false)
                }
            }
            if name == "Boolean" {
                return ["true", "false"].map {
                    GraphQLCompletion(label: $0, detail: name, kind: .keyword, isDeprecated: false)
                }
            }
            return []
        }
    }
}
