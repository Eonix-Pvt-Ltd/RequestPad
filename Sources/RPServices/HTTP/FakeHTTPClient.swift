import Foundation
import RPCore

/// Scripted ``HTTPClient`` for tests and SwiftUI previews. Records every request it receives.
public actor FakeHTTPClient: HTTPClient {
    public typealias Handler = @Sendable (ResolvedRequest) -> Result<HTTPResponse, ServiceError>
    private let handler: Handler
    public private(set) var requests: [ResolvedRequest] = []

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers every request with `status` and a JSON `body`.
    public init(
        status: Int = 200, json body: String = "{}", headers: [(name: String, value: String)] = [],
        setCookies: [String] = []
    ) {
        self.init { request in
            .success(
                FakeHTTPClient.response(
                    for: request, status: status, body: Data(body.utf8),
                    headers: [(name: "Content-Type", value: "application/json")] + headers, setCookies: setCookies))
        }
    }

    public func send(_ request: ResolvedRequest, files: any FileReferenceResolver) throws(ServiceError) -> HTTPResponse
    {
        requests.append(request)
        return try handler(request).get()
    }

    public nonisolated static func response(
        for request: ResolvedRequest, status: Int, body: Data, headers: [(name: String, value: String)] = [],
        setCookies: [String] = []
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: status, reasonPhrase: HTTPURLResponse.localizedString(forStatusCode: status).capitalized,
            headers: headers,
            setCookieHeaders: setCookies, body: .memory(body), url: request.url, redirects: [],
            timings: RequestTimings(
                dnsLookup: nil, tcpConnect: nil, tlsHandshake: nil, requestSend: nil, waiting: 1, download: 1,
                total: 12, isReusedConnection: true),
            networkProtocol: "h2", remoteAddress: "192.0.2.1:443", tlsVersion: "TLS 1.3",
            tlsCipherSuite: "TLS_AES_128_GCM_SHA256",
            headerBytes: 100, receivedAt: Date(timeIntervalSince1970: 0))
    }
}
