import Foundation

/// Per-request transport settings (F01.6).
public struct RequestSettings: Hashable, Sendable, Codable {
    public var followRedirects: Bool
    public var maximumRedirects: Int
    /// Timeout in milliseconds; `nil` or 0 uses the app default (30 s).
    public var timeoutMilliseconds: Int?

    public init(
        followRedirects: Bool = true, maximumRedirects: Int = RequestDefaults.maximumRedirects,
        timeoutMilliseconds: Int? = nil
    ) {
        self.followRedirects = followRedirects
        self.maximumRedirects = maximumRedirects
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    /// The timeout to apply, clamped to ``RequestDefaults/timeoutRange``.
    public var effectiveTimeout: Duration {
        guard let timeoutMilliseconds, timeoutMilliseconds > 0 else { return RequestDefaults.timeout }
        return RequestDefaults.clampedTimeout(.milliseconds(timeoutMilliseconds))
    }
}

/// Whether a request is plain HTTP or GraphQL (Bruno `meta.type`).
public enum RequestKind: String, Hashable, Sendable, Codable {
    case http
    case graphql
}

/// A saved or draft request (A8 `RequestItem`).
public struct RequestItem: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: RequestKind
    public var method: HTTPMethod
    public var url: String
    public var queryParams: [KeyValue]
    public var pathParams: [KeyValue]
    public var headers: [KeyValue]
    public var body: RequestBody
    public var auth: RequestAuth
    /// Request-scope variables (Bruno `vars:pre-request`).
    public var variables: [KeyValue]
    public var extractors: [Extractor]
    public var assertions: [Assertion]
    public var settings: RequestSettings
    public var docs: String
    public var tags: [String]
    public var sortOrder: Int
    /// Whether the source `.bru` file contains JavaScript (`script:*`, `tests`) that RequestPad preserves but
    /// does not run (P01.3, out of scope A6).
    public var hasUnsupportedScripts: Bool

    public init(
        id: UUID = UUID(), name: String, kind: RequestKind = .http, method: HTTPMethod = .get, url: String = "",
        queryParams: [KeyValue] = [], pathParams: [KeyValue] = [], headers: [KeyValue] = [],
        body: RequestBody = .none, auth: RequestAuth = .inherit, variables: [KeyValue] = [],
        extractors: [Extractor] = [], assertions: [Assertion] = [], settings: RequestSettings = RequestSettings(),
        docs: String = "", tags: [String] = [], sortOrder: Int = 1, hasUnsupportedScripts: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.method = method
        self.url = url
        self.queryParams = queryParams
        self.pathParams = pathParams
        self.headers = headers
        self.body = body
        self.auth = auth
        self.variables = variables
        self.extractors = extractors
        self.assertions = assertions
        self.settings = settings
        self.docs = docs
        self.tags = tags
        self.sortOrder = sortOrder
        self.hasUnsupportedScripts = hasUnsupportedScripts
    }

    /// Content equality ignoring `id` (used to detect unsaved edits and for round-trip tests).
    public func hasSameContent(as other: RequestItem) -> Bool {
        var copy = other
        copy.id = id
        return self == copy
    }
}

/// Settings shared by the requests in a folder or collection (Bruno `folder.bru` / `collection.bru`, F03.3).
public struct FolderSettings: Hashable, Sendable, Codable {
    public var headers: [KeyValue]
    public var auth: RequestAuth
    public var variables: [KeyValue]
    public var docs: String
    public var sequence: Int?

    public init(
        headers: [KeyValue] = [], auth: RequestAuth = .inherit, variables: [KeyValue] = [], docs: String = "",
        sequence: Int? = nil
    ) {
        self.headers = headers
        self.auth = auth
        self.variables = variables
        self.docs = docs
        self.sequence = sequence
    }
}

/// A folder inside a collection. `path` is relative to the collection root, `/`-separated (`users/admin`).
public struct RequestFolder: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var settings: FolderSettings

    public init(id: UUID = UUID(), name: String, path: String, settings: FolderSettings = FolderSettings()) {
        self.id = id
        self.name = name
        self.path = path
        self.settings = settings
    }
}

/// Where a collection's source of truth lives (A8 `Collection.format`).
public enum CollectionStorage: String, Hashable, Sendable, Codable {
    /// Stored in the app's database; counts toward the free limit.
    case native
    /// Bruno `.bru` files in a user-selected folder (Pro).
    case folder
    /// The bundled sample collection (ADR-0009).
    case sample
}

/// Response summary kept in history — no body, no header values (F06.1).
public struct ResponseSummary: Hashable, Sendable, Codable {
    public var statusCode: Int?
    public var durationMilliseconds: Int
    public var sizeBytes: Int
    public var contentType: String?
    /// Short, non-sensitive error description when the request failed.
    public var errorSummary: String?

    public init(
        statusCode: Int?, durationMilliseconds: Int, sizeBytes: Int, contentType: String? = nil,
        errorSummary: String? = nil
    ) {
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
        self.sizeBytes = sizeBytes
        self.contentType = contentType
        self.errorSummary = errorSummary
    }
}

/// A sent request as recorded in history. The snapshot is the unresolved request (templates, not secret values).
public struct HistoryEntry: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var request: RequestItem
    public var response: ResponseSummary
    public var sentAt: Date

    public init(id: UUID = UUID(), request: RequestItem, response: ResponseSummary, sentAt: Date) {
        self.id = id
        self.request = request
        self.response = response
        self.sentAt = sentAt
    }
}
