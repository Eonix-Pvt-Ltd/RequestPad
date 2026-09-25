import Foundation

/// The body of a request (F01.4).
public enum RequestBody: Hashable, Sendable, Codable {
    case none
    case json(String)
    case text(String)
    case xml(String)
    case formURLEncoded([KeyValue])
    case multipart([MultipartField])
    case graphQL(GraphQLBody)
    /// A body mode RequestPad does not edit (e.g. Bruno `sparql`, `file`). Preserved on save.
    case unsupported(mode: String)

    /// Bruno's name for the body mode, used in the method block's `body:` key.
    public var bruMode: String {
        switch self {
        case .none: "none"
        case .json: "json"
        case .text: "text"
        case .xml: "xml"
        case .formURLEncoded: "formUrlEncoded"
        case .multipart: "multipartForm"
        case .graphQL: "graphql"
        case .unsupported(let mode): mode
        }
    }

    /// The `Content-Type` sent when the user has not set one explicitly. `nil` for multipart (the boundary is
    /// generated at send time) and for no body.
    public var defaultContentType: String? {
        switch self {
        case .none, .multipart, .unsupported: nil
        case .json, .graphQL: "application/json"
        case .text: "text/plain; charset=utf-8"
        case .xml: "application/xml"
        case .formURLEncoded: "application/x-www-form-urlencoded"
        }
    }
}

public struct GraphQLBody: Hashable, Sendable, Codable {
    public var query: String
    /// Variables as JSON text (may contain `{{variables}}`).
    public var variables: String

    public init(query: String = "", variables: String = "") {
        self.query = query
        self.variables = variables
    }
}

/// A multipart form field: text or one or more files (F01.4).
public struct MultipartField: Hashable, Sendable, Codable, Identifiable {
    public enum Content: Hashable, Sendable, Codable {
        case text(String)
        /// File references: relative paths for folder collections, bookmark identifiers for native collections.
        case files([String])
    }

    public var id: UUID
    public var name: String
    public var content: Content
    public var contentType: String?
    public var isEnabled: Bool
    public var annotations: [String]

    public init(
        id: UUID = UUID(), name: String, content: Content, contentType: String? = nil, isEnabled: Bool = true,
        annotations: [String] = []
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.contentType = contentType
        self.isEnabled = isEnabled
        self.annotations = annotations
    }

    public static func == (lhs: MultipartField, rhs: MultipartField) -> Bool {
        lhs.name == rhs.name && lhs.content == rhs.content && lhs.contentType == rhs.contentType
            && lhs.isEnabled == rhs.isEnabled && lhs.annotations == rhs.annotations
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(content)
        hasher.combine(contentType)
        hasher.combine(isEnabled)
    }
}
