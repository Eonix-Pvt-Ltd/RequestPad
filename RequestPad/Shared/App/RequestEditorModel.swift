import Foundation
import Observation
import RPCore
import RPData
import RPServices
import RPStore

/// What a window shows in its detail area.
enum WorkspaceSelection: Hashable, Codable {
    case request(RequestReference)
    /// An unsaved request not in any collection (new request, cURL import, history re-open).
    case scratch(UUID)
    case history
}

/// Per-window state: selection and the open editor (X01.4 restores the selection per scene).
@Observable
final class WorkspaceModel {
    var selection: WorkspaceSelection? {
        didSet { if selection != oldValue { openEditor() } }
    }
    private(set) var editor: RequestEditorModel?
    let app: AppModel
    /// ⌘E opens the environment picker.
    var isEnvironmentPickerPresented = false
    /// ⌘L asks the URL field to take focus (the value changes on each request).
    var focusURLRequest: UUID?

    init(app: AppModel) {
        self.app = app
    }

    /// Opens a scratch editor for `request` (cURL import, history, New Request without a collection).
    func openScratch(_ request: RequestItem) {
        let id = UUID()
        editor = RequestEditorModel(app: app, reference: nil, request: request, draftKey: id.uuidString)
        selection = .scratch(id)
    }

    private func openEditor() {
        switch selection {
        case .request(let reference):
            guard editor?.reference != reference else { return }
            guard let entry = app.request(reference) else {
                editor = nil
                return
            }
            editor = RequestEditorModel(
                app: app, reference: reference, request: entry.request,
                draftKey: "\(reference.collectionID)/\(reference.key)")
        case .scratch:
            if editor?.reference != nil { editor = nil }
        case .history, nil:
            editor = nil
        }
    }

    /// After a rename/move the key changes; keep the editor attached.
    func followRename(to reference: RequestReference) {
        editor?.reference = reference
        selection = .request(reference)
    }
}

/// Editing, saving and sending one request.
@Observable
final class RequestEditorModel: Identifiable {
    enum SendState: Equatable {
        case idle
        case sending(startedAt: Date)
        case finished
        case failed(PresentedError)
    }

    let id = UUID()
    let app: AppModel
    var reference: RequestReference?
    private(set) var saved: RequestItem
    var request: RequestItem {
        didSet {
            if request != oldValue { scheduleDraftSave() }
        }
    }
    private(set) var sendState: SendState = .idle
    private(set) var result: SendResult?
    private(set) var conflict: DataError?
    private(set) var schema: GraphQLSchema?
    private(set) var schemaError: String?
    private(set) var isFetchingSchema = false
    private(set) var oauthMessage: String?
    /// Flags a cURL paste into the URL field didn't fully support (F07.1).
    private(set) var importNotices: [String] = []
    /// iOS: explain the Local Network prompt before the first LAN request (F01.9).
    var isLocalNetworkExplainerPresented = false
    /// Set after a successful send when the review policy allows a prompt (X02.3); the view consumes it.
    var isReviewPromptDue = false
    let draftKey: String
    private var sendTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?

    init(app: AppModel, reference: RequestReference?, request: RequestItem, draftKey: String) {
        self.app = app
        self.reference = reference
        saved = request
        self.request = request
        self.draftKey = draftKey
        Task { await restoreDraft() }
    }

    var hasUnsavedChanges: Bool { !request.hasSameContent(as: saved) }
    var isSending: Bool { if case .sending = sendState { return true } else { return false } }
    var isReadOnly: Bool { reference.map { app.isReadOnly($0.collectionID) } ?? false }

    var collectionTree: CollectionTree? { reference.flatMap { app.collection($0.collectionID)?.tree } }

    /// Variables visible to the request (for highlighting and autocomplete).
    var variableContext: VariableContext {
        let collectionID = reference?.collectionID
        var scopes = [
            VariableScope(
                kind: .runtime,
                values: (collectionID.flatMap { app.runtimeVariables[$0] } ?? [:]).mapValues(VariableValue.plain)),
            VariableScope(kind: .request, rows: request.variables),
            VariableScope(kind: .global, variables: app.globals.variables),
        ]
        if let collectionID, let environment = app.activeEnvironment(for: collectionID)?.environment {
            scopes.append(VariableScope(kind: .environment, variables: environment.variables))
        }
        if let tree = collectionTree {
            let folderKey = reference.flatMap { app.request($0)?.folderKey }
            scopes.append(
                contentsOf: tree.folderChain(to: folderKey).reversed().map {
                    VariableScope(kind: .folder, rows: $0.variables)
                })
            scopes.append(VariableScope(kind: .collection, rows: tree.settings.variables))
        }
        return VariableContext(scopes: scopes)
    }

    /// Names used in the request that have no value (F04.3).
    var unresolvedVariables: [String] {
        let preview = try? RequestResolver(interpolator: Interpolator()).resolve(
            request, context: previewContext, mode: .display)
        return preview?.unresolvedVariables ?? []
    }

    private var previewContext: ResolutionContext {
        let folderKey = reference.flatMap { app.request($0)?.folderKey }
        return ResolutionContext(
            folders: collectionTree?.folderChain(to: folderKey) ?? [],
            collection: collectionTree?.settings ?? FolderSettings(),
            variables: VariableContext(
                scopes: variableContext.scopes.filter {
                    $0.kind != .request && $0.kind != .folder && $0.kind != .collection
                }),
            oauth2AccessToken: "preview")
    }

    /// The request as it would be sent, secrets masked (cURL copy, F07.2).
    func previewResolved() throws(CoreError) -> ResolvedRequest {
        try RequestResolver(interpolator: Interpolator()).resolve(request, context: previewContext, mode: .display)
    }

    // MARK: Query sync (F01.2)

    func urlDidChange(_ url: String) {
        if url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("curl "), applyCurl(url) { return }
        request.url = url
        request.queryParams = QueryParameters.merge(
            urlRows: QueryParameters.parse(fromURL: url), into: request.queryParams)
    }

    func queryParamsDidChange(_ rows: [KeyValue]) {
        request.queryParams = rows
        request.url = QueryParameters.url(request.url, replacingQueryWith: rows)
    }

    /// Replaces the request's contents with a parsed cURL command, keeping its identity, name and docs.
    @discardableResult
    func applyCurl(_ command: String) -> Bool {
        guard !isReadOnly, let imported = try? CurlParser.parse(command) else { return false }
        var item = imported.request
        item.id = request.id
        item.name = request.name
        item.sortOrder = request.sortOrder
        item.docs = request.docs
        request = item
        importNotices = imported.notices
        return true
    }

    func dismissImportNotices() { importNotices = [] }

    // MARK: Save (F03, P01.4)

    func save(overwrite: Bool = false) async {
        guard let reference, !isReadOnly else { return }
        if request.auth.requiresPro, !app.require(.oauth2) { return }
        do {
            let updated = try await app.saveRequest(request, reference: reference, overwrite: overwrite)
            saved = request
            conflict = nil
            try? await app.environment.store.deleteDraft(key: draftKey)
            if updated != reference { self.reference = updated }
        } catch {
            if case .fileConflict = error {
                conflict = error
            } else {
                app.present(error)
            }
        }
    }

    /// "Use File" after a conflict: reloads the version on disk and drops local edits.
    func discardForFileVersion() async {
        guard let reference else { return }
        await app.reloadTree(reference.collectionID)
        if let entry = app.request(reference) {
            saved = entry.request
            request = entry.request
        }
        conflict = nil
        try? await app.environment.store.deleteDraft(key: draftKey)
    }

    func revert() async {
        request = saved
        try? await app.environment.store.deleteDraft(key: draftKey)
    }

    private func scheduleDraftSave() {
        draftTask?.cancel()
        let snapshot = request
        let key = draftKey
        let requestID = reference.flatMap { UUID(uuidString: $0.key) }
        let store = app.environment.store
        let unchanged = snapshot.hasSameContent(as: saved)
        draftTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if unchanged {
                try? await store.deleteDraft(key: key)
            } else {
                try? await store.saveDraft(snapshot, key: key, requestID: requestID)
            }
        }
    }

    private func restoreDraft() async {
        guard let draft = try? await app.environment.store.draft(key: draftKey), !draft.hasSameContent(as: saved) else {
            return
        }
        request = draft
    }

    // MARK: Send (F01.5)

    func send() {
        guard !isSending else { return }
        if request.body.bruMode == "graphql", !app.require(.graphQL) { return }
        if request.auth.requiresPro, !app.require(.oauth2) { return }
        if let url = try? previewResolved().url,
            AppPolicies.needsLocalNetworkExplainer(for: url, preferences: app.preferences)
        {
            isLocalNetworkExplainerPresented = true
            return
        }
        performSend()
    }

    /// "Continue" in the Local Network explainer.
    func confirmLocalNetworkAndSend() {
        app.preferences.localNetworkExplainerShown = true
        performSend()
    }

    private func performSend() {
        sendState = .sending(startedAt: Date())
        let snapshot = request
        let reference = reference
        sendTask = Task { [weak self] in
            guard let self else { return }
            do throws(SendError) {
                let result = try await app.send(snapshot, reference: reference)
                self.result = result
                sendState = .finished
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                if (200..<400).contains(result.response.statusCode),
                    AppPolicies.shouldRequestReview(preferences: app.preferences, appVersion: version)
                {
                    app.preferences.lastReviewPromptVersion = version
                    isReviewPromptDue = true
                }
            } catch {
                if case .network(.cancelled) = error {
                    sendState = .idle
                } else {
                    sendState = .failed(PresentedError(error))
                }
            }
        }
    }

    func cancel() {
        sendTask?.cancel()
        sendTask = nil
    }

    // MARK: GraphQL (P04)

    func loadCachedSchema() async {
        guard let url = try? previewResolved().url else { return }
        schema = try? await app.environment.schemaService.cachedSchema(for: url)?.schema
    }

    func fetchSchema() async {
        guard app.require(.graphQL) else { return }
        isFetchingSchema = true
        defer { isFetchingSchema = false }
        do {
            let resolved = try previewResolved()
            schema = try await app.environment.schemaService.schema(
                for: resolved.url, headers: resolved.headers, forceRefresh: true)
            schemaError = nil
        } catch let error as CoreError {
            schemaError = error.errorDescription
        } catch let error as SchemaFetchError {
            schemaError = error.errorDescription
        } catch {
            schemaError = error.localizedDescription
        }
    }

    // MARK: OAuth 2.0 (F05.3, F05.4)

    func oauthConfiguration() -> OAuth2Config? {
        let auth = reference.flatMap { app.request($0) }.map { _ in effectiveAuth } ?? request.auth
        if case .oauth2(let config) = auth { return config }
        return nil
    }

    private var effectiveAuth: RequestAuth {
        let folderKey = reference.flatMap { app.request($0)?.folderKey }
        return ResolutionContext(
            folders: collectionTree?.folderChain(to: folderKey) ?? [],
            collection: collectionTree?.settings ?? FolderSettings()
        )
        .effectiveAuth(for: request)
    }

    func getNewToken() async {
        guard app.require(.oauth2), let config = oauthConfiguration() else { return }
        let resolved = await app.resolvedOAuthConfig(config, context: variableContext)
        do {
            let token = try await app.environment.oauth.fetchNewToken(for: resolved)
            let expiry = token.expiresAt.map { $0.formatted(date: .omitted, time: .shortened) }
            oauthMessage =
                expiry.map { String(localized: "Token received. It expires at \($0).") }
                ?? String(localized: "Token received.")
        } catch {
            oauthMessage = nil
            app.present(error)
        }
    }

    func clearToken() async {
        guard let config = oauthConfiguration() else { return }
        let resolved = await app.resolvedOAuthConfig(config, context: variableContext)
        try? await app.environment.oauth.clearToken(for: resolved)
        oauthMessage = String(localized: "Token cleared.")
    }
}
