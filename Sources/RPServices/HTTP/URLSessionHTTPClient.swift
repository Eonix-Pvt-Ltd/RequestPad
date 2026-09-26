import Foundation
import OSLog
import RPCore

/// The live ``HTTPClient`` (F01, F02, A9): an ephemeral `URLSession` with no cookie storage or cache (the app's
/// cookie jar is applied explicitly), per-request timeouts, a redirect policy, streaming of large bodies to disk
/// and full timing/TLS metrics. User requests are sent exactly once — never retried (ADR-0007).
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let delegate: SessionDelegate
    private let configuration: HTTPClientConfiguration

    public init(configuration: HTTPClientConfiguration = HTTPClientConfiguration()) {
        self.configuration = configuration
        delegate = SessionDelegate(configuration: configuration)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForResource = 60 * 60
        sessionConfiguration.waitsForConnectivity = false
        session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: ResolvedRequest, files: any FileReferenceResolver) async throws(ServiceError)
        -> HTTPResponse
    {
        guard request.method.isValidForSending else { throw .invalidMethod(request.method.rawValue) }
        let scheme = request.url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw .unsupportedScheme(scheme) }
        let timeoutSeconds = Int(Double(request.settings.effectiveTimeout.components.seconds))

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = TimeInterval(max(timeoutSeconds, 1))
        for header in request.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }

        var uploadFile: URL?
        defer { if let uploadFile { try? FileManager.default.removeItem(at: uploadFile) } }
        let task: URLSessionTask
        switch request.body {
        case .none:
            task = session.dataTask(with: urlRequest)
        case .data(let data):
            urlRequest.httpBody = data
            task = session.dataTask(with: urlRequest)
        case .multipart(let parts):
            let output = try MultipartBodyWriter.write(parts, files: files, directory: configuration.temporaryDirectory)
            uploadFile = output.file
            if request.headerValue("Content-Type") == nil {
                urlRequest.setValue(output.contentType, forHTTPHeaderField: "Content-Type")
            }
            task = session.uploadTask(with: urlRequest, fromFile: output.file)
        }

        let startedAt = Date()
        let result: Result<HTTPResponse, ServiceError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.register(task, settings: request.settings, startedAt: startedAt) { result in
                    continuation.resume(returning: result)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        switch result {
        case .success(let response):
            Log.logger(.network).info(
                "\(request.method.rawValue, privacy: .public) \(Log.redacted(request.url), privacy: .public) → \(response.statusCode, privacy: .public)"
            )
            return response
        case .failure(let error):
            Log.logger(.network).notice(
                "\(request.method.rawValue, privacy: .public) \(Log.redacted(request.url), privacy: .public) failed: \(String(describing: error), privacy: .private)"
            )
            throw error
        }
    }
}

/// URLSession delegate holding per-task state. `@unchecked Sendable`: `tasks` is only accessed under `lock`;
/// URLSession calls delegate methods on its own serial queue.
final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Completion = @Sendable (Result<HTTPResponse, ServiceError>) -> Void

    private struct TaskState {
        var settings: RequestSettings
        var startedAt: Date
        var completion: Completion
        var response: HTTPURLResponse?
        var memory = Data()
        var fileURL: URL?
        var fileHandle: FileHandle?
        var received = 0
        var redirects: [RedirectHop] = []
        var metrics: URLSessionTaskMetrics?
        var failure: ServiceError?
    }

    private let lock = NSLock()
    private var tasks: [Int: TaskState] = [:]
    private let configuration: HTTPClientConfiguration

    init(configuration: HTTPClientConfiguration) {
        self.configuration = configuration
    }

    func register(_ task: URLSessionTask, settings: RequestSettings, startedAt: Date, completion: @escaping Completion)
    {
        lock.withLock {
            tasks[task.taskIdentifier] = TaskState(settings: settings, startedAt: startedAt, completion: completion)
        }
    }

    private func mutate(_ task: URLSessionTask, _ body: (inout TaskState) -> Void) {
        lock.withLock {
            guard var state = tasks[task.taskIdentifier] else { return }
            body(&state)
            tasks[task.taskIdentifier] = state
        }
    }

    // MARK: Response and body

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        var tooLarge = false
        mutate(dataTask) { state in
            state.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(configuration.maximumBodyBytes) {
                state.failure = .responseTooLarge(limitBytes: configuration.maximumBodyBytes)
                tooLarge = true
            }
        }
        completionHandler(tooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var shouldCancel = false
        mutate(dataTask) { state in
            guard state.failure == nil else { return }
            state.received += data.count
            if state.received > configuration.maximumBodyBytes {
                state.failure = .responseTooLarge(limitBytes: configuration.maximumBodyBytes)
                shouldCancel = true
                return
            }
            if let handle = state.fileHandle {
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    state.failure = .fileUnavailable(name: state.fileURL?.lastPathComponent ?? "response")
                    shouldCancel = true
                }
            } else if state.memory.count + data.count > configuration.maximumInMemoryBodyBytes {
                // Spill to disk: bodies above the render cap are never held whole in memory (F02.7).
                do {
                    try FileManager.default.createDirectory(
                        at: configuration.temporaryDirectory, withIntermediateDirectories: true)
                    let url = configuration.temporaryDirectory.appending(path: "response-\(UUID().uuidString).body")
                    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.write(contentsOf: state.memory)
                    try handle.write(contentsOf: data)
                    state.memory = Data()
                    state.fileURL = url
                    state.fileHandle = handle
                } catch {
                    state.failure = .fileUnavailable(name: "response")
                    shouldCancel = true
                }
            } else {
                state.memory.append(data)
            }
        }
        if shouldCancel { dataTask.cancel() }
    }

    // MARK: Redirects

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var decision: URLRequest?
        var cancel = false
        mutate(task) { state in
            guard state.settings.followRedirects else { return }
            guard let from = response.url, let to = request.url else { return }
            guard state.redirects.count < state.settings.maximumRedirects else {
                state.failure = .tooManyRedirects(state.settings.maximumRedirects)
                cancel = true
                return
            }
            state.redirects.append(RedirectHop(statusCode: response.statusCode, from: from, to: to))
            var next = request
            if Self.origin(of: from) != Self.origin(of: to) {
                // Credentials never follow a redirect to another origin.
                next.setValue(nil, forHTTPHeaderField: "Authorization")
                next.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            decision = next
        }
        if cancel {
            completionHandler(nil)
            task.cancel()
        } else {
            completionHandler(decision)
        }
    }

    static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(url.host(percentEncoded: false)?.lowercased() ?? ""):\(url.port ?? defaultPort)"
    }

    // MARK: Completion

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        mutate(task) { $0.metrics = metrics }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let removed = lock.withLock { tasks.removeValue(forKey: task.taskIdentifier) }
        guard let state = removed else { return }
        try? state.fileHandle?.close()
        let host = task.originalRequest?.url?.host(percentEncoded: false) ?? ""
        let timeout = Int(task.originalRequest?.timeoutInterval ?? 30)
        if let failure = state.failure {
            if let fileURL = state.fileURL { try? FileManager.default.removeItem(at: fileURL) }
            state.completion(.failure(failure))
            return
        }
        if let error {
            if let fileURL = state.fileURL { try? FileManager.default.removeItem(at: fileURL) }
            state.completion(.failure(ServiceError.from(error, host: host, timeoutSeconds: timeout)))
            return
        }
        guard let response = state.response, let url = response.url ?? task.currentRequest?.url else {
            state.completion(.failure(.connectionLost))
            return
        }
        state.completion(.success(Self.makeResponse(response: response, url: url, state: state)))
    }

    private static func makeResponse(response: HTTPURLResponse, url: URL, state: TaskState) -> HTTPResponse {
        var headers: [(name: String, value: String)] = []
        var headerBytes = 17
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            headerBytes += name.utf8.count + text.utf8.count + 4
            if name.caseInsensitiveCompare("Set-Cookie") != .orderedSame { headers.append((name, text)) }
        }
        headers.sort { $0.name.lowercased() < $1.name.lowercased() }
        let body: ResponseBodyStorage = state.fileURL.map { .file($0, size: state.received) } ?? .memory(state.memory)
        let transaction = state.metrics?.transactionMetrics.last
        return HTTPResponse(
            statusCode: response.statusCode,
            reasonPhrase: HTTPReasonPhrase.phrase(for: response.statusCode),
            headers: headers, setCookieHeaders: setCookieStrings(response: response, url: url), body: body, url: url,
            redirects: state.redirects, timings: timings(from: state.metrics),
            networkProtocol: transaction?.networkProtocolName,
            remoteAddress: transaction.flatMap(remoteAddress), tlsVersion: transaction.flatMap(tlsVersion),
            tlsCipherSuite: transaction.flatMap(cipherSuite), headerBytes: headerBytes, receivedAt: Date())
    }

    /// `Set-Cookie` values, split correctly by Foundation's parser (the combined header contains commas inside
    /// `Expires` dates) and re-serialized for ``RPCore/CookieJar``.
    static func setCookieStrings(response: HTTPURLResponse, url: URL) -> [String] {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
        }
        guard fields.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame }) else {
            return []
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { cookie in
            var parts = ["\(cookie.name)=\(cookie.value)", "Path=\(cookie.path)"]
            if cookie.domain.hasPrefix(".") { parts.append("Domain=\(cookie.domain.dropFirst())") }
            if let expires = cookie.expiresDate { parts.append("Expires=\(formatter.string(from: expires))") }
            if cookie.isSecure { parts.append("Secure") }
            if cookie.isHTTPOnly { parts.append("HttpOnly") }
            if let sameSite = cookie.sameSitePolicy?.rawValue { parts.append("SameSite=\(sameSite)") }
            return parts.joined(separator: "; ")
        }
    }

    static func timings(from metrics: URLSessionTaskMetrics?) -> RequestTimings? {
        guard let metrics else { return nil }
        func milliseconds(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end, end >= start else { return nil }
            return end.timeIntervalSince(start) * 1000
        }
        let transaction = metrics.transactionMetrics.last
        let tls = milliseconds(transaction?.secureConnectionStartDate, transaction?.secureConnectionEndDate)
        let connect = milliseconds(transaction?.connectStartDate, transaction?.connectEndDate).map {
            max($0 - (tls ?? 0), 0)
        }
        return RequestTimings(
            dnsLookup: milliseconds(transaction?.domainLookupStartDate, transaction?.domainLookupEndDate),
            tcpConnect: connect,
            tlsHandshake: tls, requestSend: milliseconds(transaction?.requestStartDate, transaction?.requestEndDate),
            waiting: milliseconds(transaction?.requestEndDate, transaction?.responseStartDate),
            download: milliseconds(transaction?.responseStartDate, transaction?.responseEndDate),
            total: metrics.taskInterval.duration * 1000, isReusedConnection: transaction?.isReusedConnection ?? false)
    }

    static func remoteAddress(_ transaction: URLSessionTaskTransactionMetrics) -> String? {
        guard let address = transaction.remoteAddress else { return nil }
        let host = address.contains(":") ? "[\(address)]" : address
        return transaction.remotePort.map { "\(host):\($0)" } ?? host
    }

    static func tlsVersion(_ transaction: URLSessionTaskTransactionMetrics) -> String? {
        guard let version = transaction.negotiatedTLSProtocolVersion else { return nil }
        switch version.rawValue {
        case 0x0301: return "TLS 1.0"
        case 0x0302: return "TLS 1.1"
        case 0x0303: return "TLS 1.2"
        case 0x0304: return "TLS 1.3"
        default: return String(format: "0x%04X", version.rawValue)
        }
    }

    static func cipherSuite(_ transaction: URLSessionTaskTransactionMetrics) -> String? {
        guard let suite = transaction.negotiatedTLSCipherSuite else { return nil }
        return cipherSuiteName(suite.rawValue)
    }

    static func cipherSuiteName(_ value: UInt16) -> String {
        switch value {
        case 0x1301: "TLS_AES_128_GCM_SHA256"
        case 0x1302: "TLS_AES_256_GCM_SHA384"
        case 0x1303: "TLS_CHACHA20_POLY1305_SHA256"
        case 0xC02B: "ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
        case 0xC02C: "ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
        case 0xC02F: "ECDHE_RSA_WITH_AES_128_GCM_SHA256"
        case 0xC030: "ECDHE_RSA_WITH_AES_256_GCM_SHA384"
        case 0xCCA8: "ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
        case 0xCCA9: "ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
        default: String(format: "0x%04X", value)
        }
    }
}
