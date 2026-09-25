import Foundation

/// A GraphQL schema built from an introspection result (P04.2).
public struct GraphQLSchema: Hashable, Sendable, Codable {
    public indirect enum TypeRef: Hashable, Sendable, Codable, CustomStringConvertible {
        case named(String)
        case list(TypeRef)
        case nonNull(TypeRef)

        public var namedType: String {
            switch self {
            case .named(let name): name
            case .list(let inner), .nonNull(let inner): inner.namedType
            }
        }

        public var description: String {
            switch self {
            case .named(let name): name
            case .list(let inner): "[\(inner)]"
            case .nonNull(let inner): "\(inner)!"
            }
        }
    }

    public struct Argument: Hashable, Sendable, Codable {
        public var name: String
        public var type: TypeRef
        public var description: String?

        public init(name: String, type: TypeRef, description: String? = nil) {
            self.name = name
            self.type = type
            self.description = description
        }
    }

    public struct Field: Hashable, Sendable, Codable {
        public var name: String
        public var type: TypeRef
        public var arguments: [Argument]
        public var description: String?
        public var isDeprecated: Bool

        public init(
            name: String, type: TypeRef, arguments: [Argument] = [], description: String? = nil,
            isDeprecated: Bool = false
        ) {
            self.name = name
            self.type = type
            self.arguments = arguments
            self.description = description
            self.isDeprecated = isDeprecated
        }
    }

    public enum Kind: String, Hashable, Sendable, Codable {
        case scalar = "SCALAR"
        case object = "OBJECT"
        case interface = "INTERFACE"
        case union = "UNION"
        case enumeration = "ENUM"
        case inputObject = "INPUT_OBJECT"
    }

    public struct NamedType: Hashable, Sendable, Codable {
        public var name: String
        public var kind: Kind
        public var fields: [Field]
        public var inputFields: [Argument]
        public var enumValues: [String]
        public var possibleTypes: [String]
        public var description: String?

        public init(
            name: String, kind: Kind, fields: [Field] = [], inputFields: [Argument] = [], enumValues: [String] = [],
            possibleTypes: [String] = [], description: String? = nil
        ) {
            self.name = name
            self.kind = kind
            self.fields = fields
            self.inputFields = inputFields
            self.enumValues = enumValues
            self.possibleTypes = possibleTypes
            self.description = description
        }
    }

    public var queryType: String?
    public var mutationType: String?
    public var subscriptionType: String?
    public var types: [String: NamedType]

    public init(
        queryType: String?, mutationType: String? = nil, subscriptionType: String? = nil, types: [String: NamedType]
    ) {
        self.queryType = queryType
        self.mutationType = mutationType
        self.subscriptionType = subscriptionType
        self.types = types
    }

    /// The standard introspection query sent by "Fetch Schema" (P04.2).
    public static let introspectionQuery = """
        query IntrospectionQuery {
          __schema {
            queryType { name }
            mutationType { name }
            subscriptionType { name }
            types { ...FullType }
          }
        }
        fragment FullType on __Type {
          kind name description
          fields(includeDeprecated: true) { name description args { ...InputValue } type { ...TypeRef } isDeprecated }
          inputFields { ...InputValue }
          enumValues(includeDeprecated: true) { name }
          possibleTypes { name }
        }
        fragment InputValue on __InputValue { name description type { ...TypeRef } }
        fragment TypeRef on __Type {
          kind name
          ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } }
        }
        """

    /// Parses an introspection response (`{"data": {"__schema": …}}` or the `__schema` object itself).
    public static func fromIntrospection(_ json: JSONValue) throws(CoreError) -> GraphQLSchema {
        if let errors = json["errors"]?.arrayValue, !errors.isEmpty, json["data"]?["__schema"] == nil {
            let message = errors.first?["message"]?.stringValue ?? "The server returned errors."
            throw .invalidDocument(path: "introspection", reason: String(message.prefix(200)))
        }
        guard let schema = json["data"]?["__schema"] ?? json["__schema"], case .object = schema else {
            throw .invalidDocument(
                path: "introspection",
                reason: "The response has no __schema. Introspection may be disabled on this server.")
        }
        var types: [String: NamedType] = [:]
        for typeValue in schema["types"]?.arrayValue ?? [] {
            guard let name = typeValue["name"]?.stringValue,
                let kind = Kind(rawValue: typeValue["kind"]?.stringValue ?? "")
            else {
                continue
            }
            let fields = try (typeValue["fields"]?.arrayValue ?? []).map { field throws(CoreError) in
                Field(
                    name: field["name"]?.stringValue ?? "", type: try typeRef(field["type"]),
                    arguments: try arguments(field["args"]), description: field["description"]?.stringValue,
                    isDeprecated: field["isDeprecated"]?.boolValue ?? false)
            }
            types[name] = NamedType(
                name: name, kind: kind, fields: fields, inputFields: try arguments(typeValue["inputFields"]),
                enumValues: (typeValue["enumValues"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue },
                possibleTypes: (typeValue["possibleTypes"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue },
                description: typeValue["description"]?.stringValue)
        }
        guard !types.isEmpty else { throw .invalidDocument(path: "introspection", reason: "The schema has no types.") }
        return GraphQLSchema(
            queryType: schema["queryType"]?["name"]?.stringValue,
            mutationType: schema["mutationType"]?["name"]?.stringValue,
            subscriptionType: schema["subscriptionType"]?["name"]?.stringValue, types: types)
    }

    private static func arguments(_ value: JSONValue?) throws(CoreError) -> [Argument] {
        try (value?.arrayValue ?? []).map { argument throws(CoreError) in
            Argument(
                name: argument["name"]?.stringValue ?? "", type: try typeRef(argument["type"]),
                description: argument["description"]?.stringValue)
        }
    }

    private static func typeRef(_ value: JSONValue?, depth: Int = 0) throws(CoreError) -> TypeRef {
        guard depth < 16, let value else {
            throw .invalidDocument(path: "introspection", reason: "A type reference is incomplete.")
        }
        switch value["kind"]?.stringValue {
        case "NON_NULL": return .nonNull(try typeRef(value["ofType"], depth: depth + 1))
        case "LIST": return .list(try typeRef(value["ofType"], depth: depth + 1))
        default:
            guard let name = value["name"]?.stringValue else {
                throw .invalidDocument(path: "introspection", reason: "A type reference has no name.")
            }
            return .named(name)
        }
    }

    public func fields(of typeName: String) -> [Field] {
        types[typeName]?.fields ?? []
    }

    public func field(_ name: String, of typeName: String) -> Field? {
        fields(of: typeName).first { $0.name == name }
    }
}
