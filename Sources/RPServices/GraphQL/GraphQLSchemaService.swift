import Foundation
import RPCore
import RPData

/// Where fetched schemas are cached (P04.2).
public protocol SchemaCache: Sendable {
    func cachedSchema(for endpoint: String) async throws(DataError) -> (schema: GraphQLSchema, fetchedAt: Date)?
    func cacheSchema(_ schema: GraphQLSchema, for endpoint: String, fetchedAt: Date) async throws(DataError)
}

extension LocalStore: SchemaCache {}

public enum SchemaFetchError: Error, Hashable, Sendable, LocalizedError {
    case network(ServiceError)
    case http(status: Int)
    case invalidSchema(CoreError)
    case storage(DataError)

    public var errorDescription: String? {
        switch self {
        case .network(let error): error.errorDescription
        case .http(let status):
            String(localized: "The server answered the schema request with HTTP \(status).", bundle: .module)
        case .invalidSchema(let error): error.errorDescription
        case .storage(let error): error.errorDescription
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .network(let error): error.recoverySuggestion
        case .http:
            String(localized: "Check the endpoint URL and auth; some servers disable introspection.", bundle: .module)
        case .invalidSchema:
            String(localized: "Make sure the URL is a GraphQL endpoint with introspection enabled.", bundle: .module)
        case .storage(let error): error.recoverySuggestion
        }
    }
}

/// Fetches schemas with the standard introspection query and caches them per endpoint (P04.2).
public actor GraphQLSchemaService {
    private let transport: any HTTPTransport
    private let cache: any SchemaCache
    private let retry: RetryPolicy
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport, cache: any SchemaCache, retry: RetryPolicy = RetryPolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.cache = cache
        self.retry = retry
        self.now = now
    }

    /// Cache key: scheme, lower-cased host, port and path (query and fragment ignored).
    public nonisolated static func cacheKey(for endpoint: URL) -> String {
        let scheme = endpoint.scheme?.lowercased() ?? "https"
        let host = endpoint.host(percentEncoded: false)?.lowercased() ?? ""
        let port = endpoint.port.map { ":\($0)" } ?? ""
        let path = endpoint.path(percentEncoded: true)
        return "\(scheme)://\(host)\(port)\(path.isEmpty ? "/" : path)"
    }

    public func cachedSchema(for endpoint: URL) async throws(SchemaFetchError) -> (
        schema: GraphQLSchema, fetchedAt: Date
    )? {
        do {
            return try await cache.cachedSchema(for: Self.cacheKey(for: endpoint))
        } catch {
            throw .storage(error)
        }
    }

    /// Fetches (unless cached and `forceRefresh` is false) and caches the schema. `headers` are the request's
    /// resolved headers so auth applies to introspection too.
    public func schema(for endpoint: URL, headers: [(name: String, value: String)], forceRefresh: Bool = false)
        async throws(SchemaFetchError) -> GraphQLSchema
    {
        if !forceRefresh, let cached = try await cachedSchema(for: endpoint) { return cached.schema }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        for header in headers where header.name.caseInsensitiveCompare("Content-Length") != .orderedSame {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = JSONValue.object([JSONMember("query", .string(GraphQLSchema.introspectionQuery))])
        request.httpBody = Data(JSONSerializer.string(from: body, style: .compact).utf8)
        let transport = transport
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await retry.run { () async throws(ServiceError) -> (Data, HTTPURLResponse) in
                try await transport.perform(request)
            }
        } catch {
            throw .network(error)
        }
        let schema: GraphQLSchema
        do {
            schema = try GraphQLSchema.fromIntrospection(try JSONParser().parse(data))
        } catch {
            if !(200..<300).contains(response.statusCode) { throw .http(status: response.statusCode) }
            throw .invalidSchema(error)
        }
        do {
            try await cache.cacheSchema(schema, for: Self.cacheKey(for: endpoint), fetchedAt: now())
        } catch {
            throw .storage(error)
        }
        return schema
    }
}
