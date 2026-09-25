import Foundation
import RPCore
import RPData

/// Where a response body lives (F02.7): in memory up to ``HTTPClientConfiguration/maximumInMemoryBodyBytes``,
/// otherwise in a temporary file that is deleted when the response is discarded or on next launch.
public enum ResponseBodyStorage: Sendable, Hashable {
    case memory(Data)
    case file(URL, size: Int)

    public var size: Int {
        switch self {
        case .memory(let data): data.count
        case .file(_, let size): size
        }
    }

    /// The first `count` bytes (for sniffing and the menu bar preview).
    public func prefix(_ count: Int) -> Data {
        switch self {
        case .memory(let data):
            return data.prefix(count)
        case .file(let url, _):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: count)) ?? Data()
        }
    }

    /// The whole body in memory; `nil` for file-backed bodies (callers show "Save to File…" instead).
    public var inMemoryData: Data? {
        if case .memory(let data) = self { return data }
        return nil
    }
}

/// Timing breakdown of the final transaction, in milliseconds (F02.2). Phases that didn't happen (reused
/// connection, no TLS) are `nil`.
public struct RequestTimings: Sendable, Hashable, Codable {
    public var dnsLookup: Double?
    public var tcpConnect: Double?
    public var tlsHandshake: Double?
    public var requestSend: Double?
    public var waiting: Double?
    public var download: Double?
    public var total: Double
    public var isReusedConnection: Bool
}

/// One followed redirect.
public struct RedirectHop: Sendable, Hashable {
    public var statusCode: Int
    public var from: URL
    public var to: URL
}

/// A received HTTP response.
public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var reasonPhrase: String
    /// Header fields. Repeated fields are combined by the system (RFC 9110 §5.3) except `Set-Cookie`, which is
    /// available unmerged in ``setCookieHeaders``.
    public var headers: [(name: String, value: String)]
    public var setCookieHeaders: [String]
    public var body: ResponseBodyStorage
    /// The final URL after redirects.
    public var url: URL
    public var redirects: [RedirectHop]
    public var timings: RequestTimings?
    public var networkProtocol: String?
    public var remoteAddress: String?
    public var tlsVersion: String?
    public var tlsCipherSuite: String?
    public var headerBytes: Int
    public var receivedAt: Date

    public var statusClass: HTTPStatusClass { HTTPStatusClass(statusCode: statusCode) }
    public var contentType: String? { headerValue("Content-Type") }
    public var totalBytes: Int { headerBytes + body.size }

    public func headerValue(_ name: String) -> String? {
        headers.last(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    /// Values for extractors and assertions. JSON bodies up to the render cap are parsed.
    public func snapshot() -> ResponseSnapshot {
        let json = body.inMemoryData.flatMap { data -> JSONValue? in
            guard ResponseContentKind.classify(contentType: contentType, prefix: data.prefix(512)) == .json else {
                return nil
            }
            return try? JSONParser().parse(data)
        }
        return ResponseSnapshot(
            statusCode: statusCode, headers: headers + setCookieHeaders.map { ("Set-Cookie", $0) }, jsonBody: json,
            responseTimeMilliseconds: Int(timings?.total ?? 0))
    }

    /// History summary (no body, no header values; F06.1).
    public func summary() -> ResponseSummary {
        ResponseSummary(
            statusCode: statusCode, durationMilliseconds: Int(timings?.total ?? 0), sizeBytes: body.size,
            contentType: contentType.map { String($0.split(separator: ";").first ?? "") })
    }
}

/// Settings shared by every request a client sends.
public struct HTTPClientConfiguration: Sendable {
    public var maximumInMemoryBodyBytes: Int
    /// Downloads larger than this are cancelled.
    public var maximumBodyBytes: Int
    /// Where file-backed bodies and multipart uploads are written.
    public var temporaryDirectory: URL

    public init(
        maximumInMemoryBodyBytes: Int = RequestDefaults.maximumRenderedBodyBytes,
        maximumBodyBytes: Int = 2 * 1024 * 1024 * 1024,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appending(
            path: "Responses", directoryHint: .isDirectory)
    ) {
        self.maximumInMemoryBodyBytes = maximumInMemoryBodyBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.temporaryDirectory = temporaryDirectory
    }
}

/// Opens files referenced by multipart fields (relative paths in folder collections, bookmarks in native ones).
public protocol FileReferenceResolver: Sendable {
    /// Returns a readable URL for the reference; access is balanced by the returned token's `stop()`.
    func open(_ reference: String) throws(ServiceError) -> (url: URL, access: ScopedAccess?)
}

/// Resolves references as paths relative to a base folder (folder collections) or absolute paths.
public struct PathFileResolver: FileReferenceResolver {
    public var baseDirectory: URL?

    public init(baseDirectory: URL?) {
        self.baseDirectory = baseDirectory
    }

    public func open(_ reference: String) throws(ServiceError) -> (url: URL, access: ScopedAccess?) {
        guard !reference.isEmpty else { throw .fileUnavailable(name: "(none)") }
        let url: URL
        if reference.hasPrefix("/") {
            url = URL(filePath: reference)
        } else if let baseDirectory {
            url = baseDirectory.appending(path: reference).standardizedFileURL
            // Relative references can't escape the collection folder.
            guard
                url.path(percentEncoded: false).hasPrefix(baseDirectory.standardizedFileURL.path(percentEncoded: false))
            else {
                throw .fileUnavailable(name: reference)
            }
        } else {
            throw .fileUnavailable(name: reference)
        }
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw .fileUnavailable(name: url.lastPathComponent)
        }
        return (url, nil)
    }
}

/// Sends resolved requests (F01).
public protocol HTTPClient: Sendable {
    func send(_ request: ResolvedRequest, files: any FileReferenceResolver) async throws(ServiceError) -> HTTPResponse
}
