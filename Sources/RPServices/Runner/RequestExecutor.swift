import Foundation
import RPCore
import RPData

/// Persists history entries (F06).
public protocol HistoryRecorder: Sendable {
    func appendHistory(_ entry: HistoryEntry, limit: Int) async throws(DataError)
}

/// Loads and saves the cookie jar (P07).
public protocol CookieStore: Sendable {
    func cookieJar() async throws(DataError) -> CookieJar
    func saveCookieJar(_ jar: CookieJar) async throws(DataError)
}

extension LocalStore: HistoryRecorder, CookieStore {}

/// Everything besides the request that determines how it is sent.
public struct SendContext: Sendable {
    public var folders: [FolderSettings]
    public var collection: FolderSettings
    public var environment: Environment?
    public var globals: Environment?
    /// Runtime variables (from extraction rules), highest precedence (F04.2).
    public var runtimeVariables: [String: String]
    public var useCookieJar: Bool
    public var recordHistory: Bool
    public var historyLimit: Int
    public var files: any FileReferenceResolver

    public init(
        folders: [FolderSettings] = [], collection: FolderSettings = FolderSettings(), environment: Environment? = nil,
        globals: Environment? = nil, runtimeVariables: [String: String] = [:], useCookieJar: Bool = false,
        recordHistory: Bool = true,
        historyLimit: Int = HistoryLimits.entries,
        files: any FileReferenceResolver = PathFileResolver(baseDirectory: nil)
    ) {
        self.folders = folders
        self.collection = collection
        self.environment = environment
        self.globals = globals
        self.runtimeVariables = runtimeVariables
        self.useCookieJar = useCookieJar
        self.recordHistory = recordHistory
        self.historyLimit = historyLimit
        self.files = files
    }
}

/// How many sent requests history keeps on this device.
public enum HistoryLimits {
    public static let entries = 1_000
}

/// The outcome of sending one request.
public struct SendResult: Sendable {
    /// The request as sent, with secrets masked (for display and cURL export).
    public var sentRequest: ResolvedRequest
    public var response: HTTPResponse
    public var extractions: [ExtractionResult]
    public var assertions: [AssertionResult]
    /// Runtime variables after applying extraction rules.
    public var runtimeVariables: [String: String]
    /// Extracted variables the user asked to persist to the active environment (P05.1).
    public var variablesToPersist: [String: String]
    public var unresolvedVariables: [String]
}

public enum SendError: Error, Hashable, Sendable, LocalizedError {
    case invalidRequest(CoreError)
    case network(ServiceError)
    case authorization(OAuthFlowError)
    case unsupportedAuth(String)
    case storage(DataError)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let error): error.errorDescription
        case .network(let error): error.errorDescription
        case .authorization(let error): error.errorDescription
        case .unsupportedAuth(let mode):
            String(
                localized:
                    "“\(mode)” authentication isn't supported by RequestPad, so the request can't be sent with it.",
                bundle: .module)
        case .storage(let error): error.errorDescription
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidRequest(let error): error.recoverySuggestion
        case .network(let error): error.recoverySuggestion
        case .authorization(let error): error.recoverySuggestion
        case .unsupportedAuth: String(localized: "Choose another auth type in the Auth tab.", bundle: .module)
        case .storage(let error): error.recoverySuggestion
        }
    }

    /// Short, non-sensitive text for history (F06.1).
    var historySummary: String { errorDescription.map { String($0.prefix(120)) } ?? "Failed" }
}

/// Sends a request end to end (F01, F04, F05, F06, P05–P07).
public struct RequestExecutor: Sendable {
    let client: any HTTPClient
    let secrets: any SecretStore
    let oauth: OAuth2Service?
    let history: any HistoryRecorder
    let cookies: any CookieStore
    let now: @Sendable () -> Date

    public init(
        client: any HTTPClient, secrets: any SecretStore, oauth: OAuth2Service?, history: any HistoryRecorder,
        cookies: any CookieStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.secrets = secrets
        self.oauth = oauth
        self.history = history
        self.cookies = cookies
        self.now = now
    }

    public func send(_ request: RequestItem, context: SendContext) async throws(SendError) -> SendResult {
        let startedAt = now()
        do {
            let result = try await perform(request, context: context)
            if context.recordHistory {
                let entry = HistoryEntry(request: request, response: result.response.summary(), sentAt: startedAt)
                try? await history.appendHistory(entry, limit: context.historyLimit)
            }
            return result
        } catch {
            if context.recordHistory {
                let summary = ResponseSummary(
                    statusCode: nil, durationMilliseconds: Int(now().timeIntervalSince(startedAt) * 1000), sizeBytes: 0,
                    errorSummary: error.historySummary)
                try? await history.appendHistory(
                    HistoryEntry(request: request, response: summary, sentAt: startedAt), limit: context.historyLimit)
            }
            throw error
        }
    }

    private func perform(_ request: RequestItem, context: SendContext) async throws(SendError) -> SendResult {
        let variables = VariableContext(scopes: [
            VariableScope(kind: .runtime, values: context.runtimeVariables.mapValues(VariableValue.plain)),
            VariableScope(kind: .environment, variables: context.environment?.variables ?? []),
            VariableScope(kind: .global, variables: context.globals?.variables ?? []),
        ])
        let references = (context.environment?.variables ?? []) + (context.globals?.variables ?? [])
        let snapshot: SecretSnapshot
        do {
            snapshot = try await secrets.snapshot(
                for: references.compactMap { variable -> SecretRef? in
                    if case .secret(let reference) = variable.value { return reference }
                    return nil
                })
        } catch {
            throw .storage(error)
        }
        let interpolator = Interpolator(secretResolver: snapshot.resolver)
        let resolver = RequestResolver(interpolator: interpolator)
        var resolution = ResolutionContext(
            folders: context.folders, collection: context.collection, variables: variables)

        switch resolution.effectiveAuth(for: request) {
        case .oauth2(let config):
            let fullContext = try Self.fullVariableContext(request: request, context: context, base: variables)
            let resolvedConfig = Self.interpolate(config, interpolator: interpolator, context: fullContext)
            guard let oauth else { throw .authorization(.userAuthorizationRequired) }
            do {
                resolution.oauth2AccessToken = try await oauth.accessToken(for: resolvedConfig)
            } catch {
                throw .authorization(error)
            }
        case .unsupported(let mode):
            throw .unsupportedAuth(mode)
        default:
            break
        }

        var resolved: ResolvedRequest
        var display: ResolvedRequest
        do {
            resolved = try resolver.resolve(request, context: resolution, mode: .send)
            display = try resolver.resolve(request, context: resolution, mode: .display)
        } catch {
            throw .invalidRequest(error)
        }

        var jar: CookieJar?
        if context.useCookieJar {
            do {
                jar = try await cookies.cookieJar()
            } catch {
                throw .storage(error)
            }
            let hasExplicitCookie = resolved.headerValue("Cookie") != nil
            if !hasExplicitCookie, let header = jar?.headerValue(for: resolved.url, now: now()) {
                resolved.headers.append((name: "Cookie", value: header))
                display.headers.append((name: "Cookie", value: header))
            }
        }

        let response: HTTPResponse
        do {
            response = try await client.send(resolved, files: context.files)
        } catch {
            throw .network(error)
        }

        if var updated = jar, !response.setCookieHeaders.isEmpty {
            updated.store(setCookieHeaders: response.setCookieHeaders, from: response.url, now: now())
            do {
                try await cookies.saveCookieJar(updated)
            } catch {
                throw .storage(error)
            }
        }

        let snapshotForEvaluation = response.snapshot()
        let extractions = ResponseEvaluator.extract(request.extractors, from: snapshotForEvaluation)
        var runtime = context.runtimeVariables
        var persist: [String: String] = [:]
        for extraction in extractions {
            guard case .extracted(let value) = extraction.outcome else { continue }
            runtime[extraction.variableName] = value
            if extraction.persistToEnvironment { persist[extraction.variableName] = value }
        }
        let evaluationContext = VariableContext(
            scopes: variables.scopes.filter { $0.kind != .runtime } + [
                VariableScope(kind: .runtime, values: runtime.mapValues(VariableValue.plain))
            ])
        let assertions = ResponseEvaluator.evaluate(request.assertions, against: snapshotForEvaluation) { operand in
            interpolator.interpolate(operand, in: evaluationContext).text
        }
        return SendResult(
            sentRequest: display, response: response, extractions: extractions, assertions: assertions,
            runtimeVariables: runtime,
            variablesToPersist: persist, unresolvedVariables: resolved.unresolvedVariables)
    }

    /// Variables visible to the request including request, folder and collection scopes (for OAuth fields).
    static func fullVariableContext(request: RequestItem, context: SendContext, base: VariableContext) throws(SendError)
        -> VariableContext
    {
        var scopes = base.scopes
        scopes.append(VariableScope(kind: .request, rows: request.variables))
        scopes.append(contentsOf: context.folders.reversed().map { VariableScope(kind: .folder, rows: $0.variables) })
        scopes.append(VariableScope(kind: .collection, rows: context.collection.variables))
        return VariableContext(scopes: scopes)
    }

    public static func interpolate(_ config: OAuth2Config, interpolator: Interpolator, context: VariableContext)
        -> OAuth2Config
    {
        func apply(_ text: String) -> String { interpolator.interpolate(text, in: context).text }
        var resolved = config
        resolved.accessTokenURL = apply(config.accessTokenURL)
        resolved.authorizationURL = apply(config.authorizationURL)
        resolved.callbackURL = apply(config.callbackURL)
        resolved.refreshTokenURL = apply(config.refreshTokenURL)
        resolved.clientID = apply(config.clientID)
        resolved.clientSecret = apply(config.clientSecret)
        resolved.scope = apply(config.scope)
        resolved.tokenHeaderPrefix = apply(config.tokenHeaderPrefix)
        resolved.tokenQueryKey = apply(config.tokenQueryKey)
        return resolved
    }
}
