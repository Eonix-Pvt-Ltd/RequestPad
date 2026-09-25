import Foundation
import RPCore

/// One request in a run, with its folder chain.
public struct RunItem: Sendable {
    public var request: RequestItem
    public var folders: [FolderSettings]
    public var displayPath: String

    public init(request: RequestItem, folders: [FolderSettings] = [], displayPath: String = "") {
        self.request = request
        self.folders = folders
        self.displayPath = displayPath
    }
}

/// Result of one request in a run (P06.2).
public struct RunItemResult: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        case passed
        case failed
        case error
        case skipped
    }

    public var name: String
    public var path: String
    public var method: String
    public var outcome: Outcome
    public var statusCode: Int?
    public var durationMilliseconds: Int
    public var assertionResults: [AssertionReport]
    public var errorMessage: String?

    public struct AssertionReport: Sendable, Hashable, Codable {
        public var expression: String
        public var passed: Bool?
        public var message: String?
    }
}

/// A finished run, exportable as JSON (P06.3).
public struct RunReport: Sendable, Hashable, Codable {
    public var startedAt: Date
    public var finishedAt: Date
    public var results: [RunItemResult]
    public var wasCancelled: Bool
    public var stoppedOnFailure: Bool

    public var passedCount: Int { results.filter { $0.outcome == .passed }.count }
    public var failedCount: Int { results.filter { $0.outcome == .failed || $0.outcome == .error }.count }

    public func jsonData() throws(ServiceError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(self)
        } catch {
            throw .network(code: -1, message: "The run report couldn't be encoded.")
        }
    }
}

public enum RunEvent: Sendable {
    case started(index: Int, name: String)
    case finished(index: Int, result: RunItemResult)
    case completed(RunReport)
}

/// Sends requests sequentially, carrying extracted variables forward (P06.2). Cancel the consuming task to stop.
public struct CollectionRunner: Sendable {
    let executor: RequestExecutor
    let now: @Sendable () -> Date

    public init(executor: RequestExecutor, now: @escaping @Sendable () -> Date = { Date() }) {
        self.executor = executor
        self.now = now
    }

    public func run(_ items: [RunItem], context: SendContext, stopOnFailure: Bool) -> AsyncStream<RunEvent> {
        AsyncStream { continuation in
            let task = Task {
                var runtime = context.runtimeVariables
                var results: [RunItemResult] = []
                let startedAt = now()
                var stopped = false
                for (index, item) in items.enumerated() {
                    if Task.isCancelled { break }
                    continuation.yield(.started(index: index, name: item.request.name))
                    var itemContext = context
                    itemContext.folders = item.folders
                    itemContext.runtimeVariables = runtime
                    let result: RunItemResult
                    do throws(SendError) {
                        let sent = try await executor.send(item.request, context: itemContext)
                        runtime = sent.runtimeVariables
                        result = Self.result(for: item, sent: sent)
                    } catch {
                        if case .network(.cancelled) = error, Task.isCancelled { break }
                        result = RunItemResult(
                            name: item.request.name, path: item.displayPath, method: item.request.method.rawValue,
                            outcome: .error,
                            statusCode: nil, durationMilliseconds: 0, assertionResults: [],
                            errorMessage: error.errorDescription)
                    }
                    results.append(result)
                    continuation.yield(.finished(index: index, result: result))
                    if stopOnFailure, result.outcome == .failed || result.outcome == .error {
                        stopped = true
                        break
                    }
                }
                let report = RunReport(
                    startedAt: startedAt, finishedAt: now(), results: results, wasCancelled: Task.isCancelled,
                    stoppedOnFailure: stopped)
                continuation.yield(.completed(report))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func result(for item: RunItem, sent: SendResult) -> RunItemResult {
        let reports = sent.assertions.map { assertion -> RunItemResult.AssertionReport in
            let expression = "\(assertion.assertion.rawKey): \(assertion.assertion.rawValue)"
            switch assertion.outcome {
            case .passed: return .init(expression: expression, passed: true, message: nil)
            case .failed(let message): return .init(expression: expression, passed: false, message: message)
            case .skipped(let message): return .init(expression: expression, passed: nil, message: message)
            }
        }
        let failed = sent.assertions.contains { $0.didFail }
        return RunItemResult(
            name: item.request.name, path: item.displayPath, method: item.request.method.rawValue,
            outcome: failed ? .failed : .passed,
            statusCode: sent.response.statusCode, durationMilliseconds: Int(sent.response.timings?.total ?? 0),
            assertionResults: reports,
            errorMessage: nil)
    }
}
