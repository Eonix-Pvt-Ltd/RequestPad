import Foundation
import Network
import OSLog

/// Local Echo: an in-process HTTP/1.1 test server on 127.0.0.1 (F08, A12). Off by default; evaluates no user
/// code and downloads nothing. macOS needs `com.apple.security.network.server` for the listener (A10).
public actor LocalEchoServer {
    public static let maximumConnections = 16
    public static let idleTimeout: TimeInterval = 30

    private var listener: EchoListener?
    public private(set) var port: UInt16?

    public init() {}

    public var isRunning: Bool { listener != nil }

    /// `http://127.0.0.1:<port>` while running (the `echoBaseURL` global variable, F08.1).
    public var baseURL: URL? { port.flatMap { URL(string: "http://127.0.0.1:\($0)") } }

    /// Starts the server (idempotent) and returns its port.
    @discardableResult
    public func start() async throws(ServiceError) -> UInt16 {
        if let port { return port }
        let listener = EchoListener()
        let result: Result<UInt16, ServiceError> = await withCheckedContinuation { continuation in
            listener.start { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let port):
            self.listener = listener
            self.port = port
            Log.logger(.echo).info("Local Echo started on port \(port, privacy: .public)")
            return port
        case .failure(let error):
            listener.stop()
            throw error
        }
    }

    public func stop() {
        listener?.stop()
        listener = nil
        port = nil
        Log.logger(.echo).info("Local Echo stopped")
    }

    /// Open connections (tests, diagnostics).
    public var connectionCount: Int { listener?.connectionCount ?? 0 }
}

/// Network.framework listener. All state is confined to `queue`.
final class EchoListener: @unchecked Sendable {
    // @unchecked: every mutable property is accessed only on `queue`.
    private let queue = DispatchQueue(label: "lk.eonix.RequestPad.LocalEcho")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: EchoConnection] = [:]
    private var didReport = false

    var connectionCount: Int { queue.sync { connections.count } }

    func start(completion: @escaping @Sendable (Result<UInt16, ServiceError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            parameters.allowLocalEndpointReuse = true
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                completion(.failure(.echoUnavailable(String(describing: error))))
                return
            }
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.didReport, let port = listener.port?.rawValue else { return }
                    self.didReport = true
                    completion(.success(port))
                case .failed(let error):
                    if !self.didReport {
                        self.didReport = true
                        completion(.failure(.echoUnavailable(String(describing: error))))
                    }
                    listener.cancel()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.close() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connections.count < LocalEchoServer.maximumConnections else {
            connection.cancel()
            return
        }
        let handler = EchoConnection(connection: connection, queue: queue) { [weak self] closed in
            self?.connections[ObjectIdentifier(closed)] = nil
        }
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }
}

/// One client connection: parses requests, answers them, keeps the connection alive until idle or closed.
final class EchoConnection: @unchecked Sendable {
    // @unchecked: all mutable state is accessed only on `queue`.
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClose: (EchoConnection) -> Void
    private var parser = EchoRequestParser()
    private var idleTimer: DispatchWorkItem?
    private var isClosed = false
    private var isResponding = false

    init(connection: NWConnection, queue: DispatchQueue, onClose: @escaping (EchoConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        resetIdleTimer()
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        idleTimer?.cancel()
        connection.cancel()
        onClose(self)
    }

    private func resetIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.close() }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + LocalEchoServer.idleTimeout, execute: timer)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.resetIdleTimer()
                self.parser.append(data)
                self.processRequests()
            }
            if isComplete || error != nil {
                if !self.isResponding { self.close() }
                return
            }
            self.receive()
        }
    }

    private func processRequests() {
        guard !isResponding, !isClosed else { return }
        let request: EchoRequest?
        do {
            request = try parser.next()
        } catch let error {
            let status = error == .bodyTooLarge ? 413 : (error == .headersTooLarge ? 431 : 400)
            let body = Data(#"{"error":"The request couldn't be read by Local Echo."}"#.utf8)
            send(
                EchoResponse(
                    status: status, headers: [EchoHeader(name: "Content-Type", value: "application/json")], body: body),
                keepAlive: false)
            return
        }
        guard let request else { return }
        let response = EchoRouter.respond(to: request)
        isResponding = true
        let deliver: @Sendable () -> Void = { [weak self] in self?.send(response, keepAlive: request.keepAlive) }
        if response.delayMilliseconds > 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(response.delayMilliseconds), execute: deliver)
        } else {
            deliver()
        }
    }

    private func send(_ response: EchoResponse, keepAlive: Bool) {
        guard !isClosed else { return }
        connection.send(
            content: response.serialized(keepAlive: keepAlive),
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.isResponding = false
                if error != nil || !keepAlive {
                    self.close()
                } else {
                    self.resetIdleTimer()
                    self.processRequests()
                }
            })
    }
}
