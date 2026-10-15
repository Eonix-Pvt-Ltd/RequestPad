import AppIntents
import Foundation
import RPCore
import RPServices

/// Shortcuts "Send Request" (P08): sends a saved request without opening the app and returns the status,
/// time and body.
struct SendRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Request"
    static let description = IntentDescription(
        "Sends a saved RequestPad request and returns the response status, time and body.")
    static let openAppWhenRun = false

    @Parameter(title: "Request")
    var request: RequestEntity

    @Parameter(title: "Environment", description: "Leave empty to use the collection's active environment.")
    var environment: EnvironmentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$request)") {
            \.$environment
        }
    }

    init() {}

    init(request: RequestEntity, environment: EnvironmentEntity? = nil) {
        self.request = request
        self.environment = environment
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SentResponse> & ProvidesDialog {
        let response = try await Self.send(request: request, environment: environment)
        return .result(value: response, dialog: IntentDialog(stringLiteral: response.summary))
    }

    /// The work of `perform()`, separate so tests can call it and inspect the result.
    @MainActor
    static func send(request: RequestEntity, environment: EnvironmentEntity?) async throws(IntentFailure)
        -> SentResponse
    {
        let model: AppModel
        do {
            model = try await AppRuntime.shared.loadedModel()
        } catch {
            throw .unavailable(error.errorDescription ?? "")
        }
        guard let reference = request.reference, let entry = model.request(reference) else { throw .requestNotFound }
        var choice = EnvironmentChoice.active
        if let environment {
            guard let target = environment.target, target.collectionID == reference.collectionID else {
                throw .environmentMismatch
            }
            choice = .key(target.key)
        }
        let result: SendResult
        do {
            result = try await model.send(entry.request, reference: reference, environment: choice)
        } catch {
            throw .sendFailed(error.errorDescription ?? "")
        }
        let content = await ResponseContent.load(from: result.response)
        return SentResponse(
            statusCode: result.response.statusCode, reasonPhrase: result.response.reasonPhrase,
            durationMilliseconds: Int(result.response.timings?.total ?? 0),
            body: content.kind == .binary || content.kind == .image
                ? String(localized: "(\(ByteFormat.string(result.response.body.size)) of binary data)") : content.text)
    }
}

/// The value "Send Request" returns; each property is available to later Shortcuts actions.
struct SentResponse: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Response"

    @Property(title: "Status Code")
    var statusCode: Int

    @Property(title: "Status")
    var reasonPhrase: String

    @Property(title: "Duration (ms)")
    var durationMilliseconds: Int

    /// Text bodies (the first 1 MB, decoded with the response's charset); binary bodies are described, not included.
    @Property(title: "Body")
    var body: String

    init() {
        statusCode = 0
        reasonPhrase = ""
        durationMilliseconds = 0
        body = ""
    }

    init(statusCode: Int, reasonPhrase: String, durationMilliseconds: Int, body: String) {
        self.init()
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.durationMilliseconds = durationMilliseconds
        self.body = body
    }

    var summary: String { "\(statusCode) \(reasonPhrase) · \(durationMilliseconds) ms" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(summary)")
    }
}

/// Why "Send Request" could not run, in words a Shortcuts user can act on (P08.2).
enum IntentFailure: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case requestNotFound
    case environmentMismatch
    case sendFailed(String)
    case unavailable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .requestNotFound:
            "The request no longer exists in RequestPad. Choose it again in the shortcut."
        case .environmentMismatch:
            "The environment belongs to a different collection than the request."
        case .sendFailed(let reason):
            "The request couldn't be sent. \(reason)"
        case .unavailable(let reason):
            "RequestPad couldn't open its data. \(reason)"
        }
    }
}

/// App Shortcuts that appear without setup.
struct RequestPadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendRequestIntent(),
            phrases: ["Send a request with \(.applicationName)", "Send a \(.applicationName) request"],
            shortTitle: "Send Request", systemImageName: "paperplane")
    }
}
