import Foundation
import RPCore

/// Minimal request/response transport for app-initiated calls (OAuth token endpoints, GraphQL introspection).
/// User requests go through ``HTTPClient`` instead.
public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws(ServiceError) -> (Data, HTTPURLResponse)
}

/// Live transport: ephemeral session, no cookies or cache, 30 s timeout, 10 MB response cap.
public final class URLSessionTransport: HTTPTransport {
    public static let maximumResponseBytes = 10 * 1024 * 1024
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func perform(_ request: URLRequest) async throws(ServiceError) -> (Data, HTTPURLResponse) {
        let host = request.url?.host(percentEncoded: false) ?? ""
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.connectionLost }
            guard data.count <= Self.maximumResponseBytes else {
                throw ServiceError.responseTooLarge(limitBytes: Self.maximumResponseBytes)
            }
            return (data, http)
        } catch {
            throw ServiceError.from(error, host: host, timeoutSeconds: 30)
        }
    }
}

/// Scripted transport for tests: responds with handlers in order and records requests.
public actor FakeTransport: HTTPTransport {
    /// Untyped `throws`: typed-throws function values need the macOS 15 / iOS 18 runtime (ADR-0032).
    public typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    private var handlers: [Handler]
    public private(set) var requests: [URLRequest] = []

    public init(_ handlers: [Handler]) {
        self.handlers = handlers
    }

    public func perform(_ request: URLRequest) throws(ServiceError) -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !handlers.isEmpty else { throw .network(code: -1, message: "No scripted response") }
        let handler = handlers.count > 1 ? handlers.removeFirst() : handlers[0]
        let status: Int
        let headers: [String: String]
        let body: Data
        do {
            (status, headers, body) = try handler(request)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw .network(code: -1, message: error.localizedDescription)
        }
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { throw .connectionLost }
        return (body, response)
    }
}

/// Exponential backoff with full jitter for app-initiated calls (B1, ADR-0007): retries 429 and 5xx (except 501)
/// and transient connection errors, honoring `Retry-After`.
public struct RetryPolicy: Sendable {
    public var maximumAttempts: Int
    public var baseDelay: Duration
    public var maximumDelay: Duration
    public var sleep: @Sendable (Duration) async throws -> Void
    public var random: @Sendable () -> Double

    public init(
        maximumAttempts: Int = 3, baseDelay: Duration = .milliseconds(500), maximumDelay: Duration = .seconds(8),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.maximumAttempts = maximumAttempts
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.sleep = sleep
        self.random = random
    }

    public static func isRetryable(status: Int) -> Bool {
        status == 429 || ((500...599).contains(status) && status != 501)
    }

    static func isRetryable(_ error: ServiceError) -> Bool {
        switch error {
        case .timedOut, .connectionLost, .cannotConnect: true
        default: false
        }
    }

    /// Delay before retry number `attempt` (1-based): `Retry-After` when present (capped), otherwise full jitter.
    public func delay(forRetry attempt: Int, retryAfter: String?, now: Date = Date()) -> Duration {
        if let retryAfter {
            if let seconds = Int(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
                return min(.seconds(seconds), .seconds(30))
            }
            if let date = HTTPDateFormat.parse(retryAfter) {
                return min(.seconds(max(date.timeIntervalSince(now), 0)), .seconds(30))
            }
        }
        let exponential = baseDelay * Int(pow(2.0, Double(max(attempt - 1, 0))))
        let capped = min(exponential, maximumDelay)
        return capped * random()
    }

    public func run(
        _ operation: () async throws(ServiceError) -> (Data, HTTPURLResponse)
    ) async throws(ServiceError) -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            do {
                let (data, response) = try await operation()
                guard Self.isRetryable(status: response.statusCode), attempt < maximumAttempts else {
                    return (data, response)
                }
                try await wait(delay(forRetry: attempt, retryAfter: response.value(forHTTPHeaderField: "Retry-After")))
            } catch {
                guard Self.isRetryable(error), attempt < maximumAttempts else { throw error }
                try await wait(delay(forRetry: attempt, retryAfter: nil))
            }
            attempt += 1
        }
    }

    private func wait(_ duration: Duration) async throws(ServiceError) {
        do {
            try await sleep(duration)
        } catch {
            throw .cancelled
        }
    }
}

enum HTTPDateFormat {
    static func parse(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
