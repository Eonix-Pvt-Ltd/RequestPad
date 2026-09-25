import Foundation
import OSLog
import Observation
import RPCore
import RPData
import RPServices
import RPStore

/// Identifies a saved request (collection + storage key).
struct RequestReference: Hashable, Codable, Sendable {
    var collectionID: UUID
    var key: String
}

/// A collection as shown in the sidebar.
struct CollectionState: Identifiable {
    var summary: CollectionSummary
    var tree: CollectionTree?
    var session: (any CollectionSession)?
    /// Why the collection can't be shown (e.g. folder access lost).
    var problem: DataError?
    var id: UUID { summary.id }
}

/// An error to show in an alert, with its recovery suggestion.
struct PresentedError: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String

    init(_ error: some LocalizedError, title: String? = nil) {
        self.title = title ?? (error.errorDescription ?? String(localized: "Something went wrong"))
        message = error.recoverySuggestion ?? ""
    }

    static func == (lhs: PresentedError, rhs: PresentedError) -> Bool { lhs.id == rhs.id }
}

/// Shared app data for every window (collections, environments, history, sending). Per-window state lives in
/// ``WorkspaceModel``.
@Observable
final class AppModel {
    let environment: AppEnvironment
    let entitlements: EntitlementState

    private(set) var collections: [CollectionState] = []
    private(set) var globals = Environment(id: SampleData.globalsID, name: String(localized: "Globals"))
    private(set) var history: [HistoryEntry] = []
    private(set) var isLoaded = false
    private(set) var echoPort: UInt16?
    /// Extracted variables per collection for this app session (F04.2 runtime scope).
    private(set) var runtimeVariables: [UUID: [String: String]] = [:]
    /// Active environment key per collection.
    private(set) var activeEnvironmentKeys: [UUID: String] = [:]
    /// Pro feature the user tried to use (drives the upgrade sheet).
    var requestedProFeature: ProFeature?
    var presentedError: PresentedError?
    var onboardingCompleted: Bool
    /// Mirrors ``Preferences/appearance`` so windows update when it changes.
    var appearance: Preferences.Appearance {
        didSet { preferences.appearance = appearance }
    }

    private var watchTasks: [UUID: Task<Void, Never>] = [:]
    private let log = Log.logger(.app)

    init(environment: AppEnvironment, entitlements: EntitlementState) {
        self.environment = environment
        self.entitlements = entitlements
        onboardingCompleted = environment.preferences.onboardingCompleted
        appearance = environment.preferences.appearance
    }

    var gate: FeatureGate { entitlements.gate }
    var preferences: Preferences { environment.preferences }

    // MARK: Loading

    func load() async {
        guard !isLoaded else { return }
        purgeTemporaryBodies()
        environment.metrics.start()
        if preferences.localEchoEnabled { await startEcho() }
        await reloadCollections()
        await reloadGlobals()
        await reloadHistory()
        isLoaded = true
    }

    func reloadCollections() async {
        do {
            let summaries = try await environment.store.collections()
            var states: [CollectionState] = []
            for summary in summaries {
                if let existing = collections.first(where: { $0.id == summary.id }), let session = existing.session {
                    var state = existing
                    state.summary = summary
                    state.tree = try? await session.load()
                    states.append(state)
                } else {
                    states.append(await openState(for: summary))
                }
            }
            for removed in collections where !summaries.contains(where: { $0.id == removed.id }) {
                watchTasks[removed.id]?.cancel()
                watchTasks[removed.id] = nil
                await removed.session?.close()
            }
            collections = states
            for state in states {
                activeEnvironmentKeys[state.id] = activeEnvironmentKeys[state.id] ?? restoredEnvironmentKey(for: state)
            }
        } catch {
            present(error)
        }
    }

    private func openState(for summary: CollectionSummary) async -> CollectionState {
        let session: any CollectionSession
        switch summary.storage {
        case .native, .sample:
            session = NativeCollectionSession(
                id: summary.id, storage: summary.storage, store: environment.store,
                files: BookmarkFileResolver(baseDirectory: nil, folderAccess: environment.folderAccess))
        case .folder:
            guard let bookmark = summary.bookmark else {
                return CollectionState(summary: summary, tree: nil, session: nil, problem: .bookmarkStale)
            }
            let store = environment.store
            do {
                session = try await FolderCollectionSession(
                    id: summary.id, bookmark: bookmark, folderAccess: environment.folderAccess,
                    refreshBookmark: { fresh in try? await store.updateCollectionBookmark(summary.id, bookmark: fresh) }
                )
            } catch {
                return CollectionState(summary: summary, tree: nil, session: nil, problem: error)
            }
            watch(session, collectionID: summary.id)
        }
        do {
            return CollectionState(summary: summary, tree: try await session.load(), session: session, problem: nil)
        } catch {
            return CollectionState(summary: summary, tree: nil, session: session, problem: error)
        }
    }

    /// Reloads a folder collection when its files change outside RequestPad (P01.4).
    private func watch(_ session: any CollectionSession, collectionID: UUID) {
        watchTasks[collectionID]?.cancel()
        watchTasks[collectionID] = Task { [weak self] in
            for await _ in session.externalChanges() {
                await self?.reloadTree(collectionID)
            }
        }
    }

    func reloadTree(_ collectionID: UUID) async {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }),
            let session = collections[index].session
        else { return }
        do {
            collections[index].tree = try await session.load()
            collections[index].problem = nil
        } catch {
            collections[index].problem = error
        }
    }

    func collection(_ id: UUID) -> CollectionState? { collections.first { $0.id == id } }

    func request(_ reference: RequestReference) -> CollectionTree.Request? {
        collection(reference.collectionID)?.tree?.requests.first { $0.key == reference.key }
    }

    /// Non-sample collections, in sidebar order (free-tier counting, F03.2).
    var userCollections: [CollectionState] { collections.filter { $0.summary.storage != .sample } }

    // MARK: Gating

    /// Returns true when allowed; otherwise shows the upgrade sheet.
    @discardableResult
    func require(_ decision: GateDecision) -> Bool {
        switch decision {
        case .allowed:
            return true
        case .requiresPro(let feature):
            requestedProFeature = feature
            return false
        }
    }

    func require(_ feature: ProFeature) -> Bool { require(gate.check(feature)) }

    func isReadOnly(_ collectionID: UUID) -> Bool {
        guard let state = collection(collectionID), state.summary.storage == .native else { return false }
        let index = userCollections.filter { $0.summary.storage == .native }.firstIndex { $0.id == collectionID } ?? 0
        return gate.isReadOnly(collectionIndexAmongNonSample: index, requestCount: state.tree?.requests.count ?? 0)
    }

    // MARK: Collections

    @discardableResult
    func createCollection(named name: String) async -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard require(gate.canCreateCollection(existingNonSampleCount: userCollections.count)) else { return nil }
        do {
            let summary = try await environment.store.createCollection(name: trimmed, storage: .native)
            await reloadCollections()
            return summary.id
        } catch {
            present(error)
            return nil
        }
    }

    /// Adds a Bruno folder the user picked (Pro, P01.1). Creates a new collection if the folder is empty.
    @discardableResult
    func openFolderCollection(at url: URL, createIfEmpty name: String?) async -> UUID? {
        guard require(.folderCollections) else { return nil }
        let access = environment.folderAccess.beginAccess(to: url)
        defer { access.stop() }
        do {
            let hasManifest = FileManager.default.fileExists(
                atPath: url.appending(path: BrunoManifest.fileName).path(percentEncoded: false))
            if !hasManifest {
                guard let name else { throw DataError.notABrunoCollection }
                try FolderCollectionRepository.createCollection(named: name, in: url)
            }
            let bookmark = try environment.folderAccess.makeBookmark(for: url)
            let snapshotName = try await FolderCollectionRepository(root: url, collectionKey: "probe").load().name
            let summary = try await environment.store.createCollection(
                name: snapshotName, storage: .folder, bookmark: bookmark)
            await reloadCollections()
            return summary.id
        } catch {
            present(error)
            return nil
        }
    }

    /// Re-grants access to a folder whose bookmark went stale (P01.1).
    func regrantAccess(_ collectionID: UUID, url: URL) async {
        let access = environment.folderAccess.beginAccess(to: url)
        defer { access.stop() }
        do {
            try await environment.store.updateCollectionBookmark(
                collectionID, bookmark: try environment.folderAccess.makeBookmark(for: url))
            collections.removeAll { $0.id == collectionID }
            await reloadCollections()
        } catch {
            present(error)
        }
    }

    func renameCollection(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform { try await self.environment.store.renameCollection(id, to: trimmed) }
    }

    /// Removes a collection from RequestPad. Folder collections' files stay on disk.
    func deleteCollection(_ id: UUID) async {
        await perform { try await self.environment.store.deleteCollection(id) }
        runtimeVariables[id] = nil
    }

    func moveCollections(from source: IndexSet, to destination: Int) async {
        let all = collections.map(\.id)
        var ids = all.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = min(destination - source.filter { $0 < destination }.count, ids.count)
        ids.insert(contentsOf: source.map { all[$0] }, at: max(insertion, 0))
        await perform { try await self.environment.store.reorderCollections(ids) }
    }

    func setCookieJar(_ enabled: Bool, for id: UUID) async {
        if enabled, !require(.cookieJar) { return }
        await perform { try await self.environment.store.setCookieJarEnabled(enabled, for: id) }
    }

    func saveCollectionSettings(_ settings: FolderSettings, for id: UUID) async {
        guard let session = collection(id)?.session else { return }
        if settings.auth.requiresPro, !require(.oauth2) { return }
        await perform(reloading: id) { try await session.saveCollectionSettings(settings) }
    }

    /// Writes a native collection to a Bruno folder and adds it as a folder collection (P01.7).
    func convertToFolder(_ id: UUID, destination: URL) async {
        guard require(.folderCollections), let tree = collection(id)?.tree else { return }
        let access = environment.folderAccess.beginAccess(to: destination)
        defer { access.stop() }
        do {
            let native = try await environment.store.nativeCollection(id)
            try await NativeCollectionExporter.export(
                native, environments: tree.environments.map(\.environment), to: destination,
                collectionKey: UUID().uuidString)
            _ = await openFolderCollection(at: destination, createIfEmpty: nil)
        } catch {
            present(error)
        }
    }

    // MARK: Folders and requests

    @discardableResult
    func createFolder(in collectionID: UUID, parentKey: String?, name: String) async -> String? {
        guard let session = collection(collectionID)?.session else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var key: String?
        await perform(reloading: collectionID) {
            key = try await session.createFolder(named: trimmed, parentKey: parentKey)
        }
        return key
    }

    func renameFolder(in collectionID: UUID, key: String, to name: String) async {
        guard let session = collection(collectionID)?.session else { return }
        await perform(reloading: collectionID) { _ = try await session.renameFolder(key: key, to: name) }
    }

    func deleteFolder(in collectionID: UUID, key: String) async {
        guard let session = collection(collectionID)?.session else { return }
        await perform(reloading: collectionID) { try await session.deleteFolder(key: key) }
    }

    func saveFolderSettings(_ settings: FolderSettings, in collectionID: UUID, key: String) async {
        guard let session = collection(collectionID)?.session else { return }
        if settings.auth.requiresPro, !require(.oauth2) { return }
        await perform(reloading: collectionID) { try await session.saveFolderSettings(settings, key: key) }
    }

    /// Creates a new request and returns its reference (F03.1, F03.2 limits).
    func createRequest(in collectionID: UUID, folderKey: String?, request: RequestItem? = nil) async
        -> RequestReference?
    {
        guard let state = collection(collectionID), let session = state.session else { return nil }
        if state.summary.storage == .native,
            !require(gate.canAddRequest(toCollectionWith: state.tree?.requests.count ?? 0))
        {
            return nil
        }
        var item = request ?? RequestItem(name: String(localized: "New Request"), url: "https://")
        item.id = UUID()
        let siblings = state.tree?.children(of: folderKey).requests ?? []
        item.sortOrder = (siblings.map(\.request.sortOrder).max() ?? 0) + 1
        do {
            let key = try await session.saveRequest(item, key: nil, folderKey: folderKey, overwrite: false)
            await reloadTree(collectionID)
            return RequestReference(collectionID: collectionID, key: key)
        } catch {
            present(error)
            return nil
        }
    }

    func duplicateRequest(_ reference: RequestReference) async -> RequestReference? {
        guard let entry = request(reference) else { return nil }
        var copy = entry.request
        copy.name = String(localized: "\(entry.request.name) Copy")
        return await createRequest(in: reference.collectionID, folderKey: entry.folderKey, request: copy)
    }

    /// Saves an edited request. Returns the (possibly new) reference, or nil on failure/conflict.
    func saveRequest(_ request: RequestItem, reference: RequestReference, overwrite: Bool = false)
        async throws(DataError) -> RequestReference
    {
        guard let state = collection(reference.collectionID), let session = state.session else {
            throw .notFound(what: "collection")
        }
        let folderKey = state.tree?.requests.first { $0.key == reference.key }?.folderKey
        let key = try await session.saveRequest(request, key: reference.key, folderKey: folderKey, overwrite: overwrite)
        await reloadTree(reference.collectionID)
        return RequestReference(collectionID: reference.collectionID, key: key)
    }

    func renameRequest(_ reference: RequestReference, to name: String) async -> RequestReference? {
        guard let session = collection(reference.collectionID)?.session, let entry = request(reference) else {
            return nil
        }
        do {
            let key = try await session.renameRequest(entry.request, key: reference.key, to: name)
            await reloadTree(reference.collectionID)
            return RequestReference(collectionID: reference.collectionID, key: key)
        } catch {
            present(error)
            return nil
        }
    }

    func moveRequest(_ reference: RequestReference, toFolder folderKey: String?, position: Int) async
        -> RequestReference?
    {
        guard let session = collection(reference.collectionID)?.session else { return nil }
        do {
            let key = try await session.moveRequest(key: reference.key, toFolder: folderKey, position: position)
            await reloadTree(reference.collectionID)
            return RequestReference(collectionID: reference.collectionID, key: key)
        } catch {
            present(error)
            return nil
        }
    }

    /// "Move Up/Down" for keyboard and VoiceOver users (F03.1).
    func nudgeRequest(_ reference: RequestReference, by offset: Int) async -> RequestReference? {
        guard let tree = collection(reference.collectionID)?.tree, let entry = request(reference) else { return nil }
        let siblings = tree.children(of: entry.folderKey).requests
        guard let index = siblings.firstIndex(where: { $0.key == reference.key }) else { return nil }
        let target = min(max(index + offset, 0), siblings.count - 1)
        guard target != index else { return reference }
        return await moveRequest(reference, toFolder: entry.folderKey, position: target)
    }

    func deleteRequest(_ reference: RequestReference) async {
        guard let session = collection(reference.collectionID)?.session else { return }
        await perform(reloading: reference.collectionID) { try await session.deleteRequest(key: reference.key) }
    }

    // MARK: Environments (F04)

    func environments(for collectionID: UUID) -> [CollectionTree.EnvironmentEntry] {
        collection(collectionID)?.tree?.environments ?? []
    }

    func activeEnvironment(for collectionID: UUID) -> CollectionTree.EnvironmentEntry? {
        guard let key = activeEnvironmentKeys[collectionID] else { return nil }
        return environments(for: collectionID).first { $0.key == key }
    }

    func setActiveEnvironment(_ key: String?, for collectionID: UUID) {
        activeEnvironmentKeys[collectionID] = key
        let id = key.flatMap { key in environments(for: collectionID).first { $0.key == key }?.environment.id }
        preferences.setActiveEnvironment(id, for: collectionID)
    }

    private func restoredEnvironmentKey(for state: CollectionState) -> String? {
        guard let id = preferences.activeEnvironment(for: state.id) else { return nil }
        return state.tree?.environments.first { $0.environment.id == id }?.key
    }

    /// Saves an environment; `secretValues` are written to the Keychain (never to the collection, F04.4).
    @discardableResult
    func saveEnvironment(
        _ environment: Environment, key: String?, in collectionID: UUID, secretValues: [String: String]
    ) async -> String? {
        guard let session = collection(collectionID)?.session else { return nil }
        do {
            let savedKey = try await session.saveEnvironment(environment, key: key)
            let secretKey = session.secretKey(forEnvironment: savedKey)
            try await storeSecrets(
                environment, secretKey: secretKey, values: secretValues, into: session, savedKey: savedKey)
            await reloadTree(collectionID)
            return savedKey
        } catch {
            present(error)
            return nil
        }
    }

    /// Secret variables reference `SecretRef.environmentVariable(environmentKey:name:)`; rewrite references created
    /// before the environment had its final key, then store values.
    private func storeSecrets(
        _ environment: Environment, secretKey: String, values: [String: String], into session: any CollectionSession,
        savedKey: String
    ) async throws(DataError) {
        var normalized = environment
        var changed = false
        for index in normalized.variables.indices {
            guard case .secret(let reference) = normalized.variables[index].value else { continue }
            let expected = SecretRef.environmentVariable(
                environmentKey: secretKey, name: normalized.variables[index].name)
            if reference != expected {
                if let old = try await self.environment.secrets.secret(for: reference),
                    values[normalized.variables[index].name] == nil
                {
                    try await self.environment.secrets.setSecret(old, for: expected)
                }
                normalized.variables[index].value = .secret(expected)
                changed = true
            }
            if let value = values[normalized.variables[index].name] {
                try await self.environment.secrets.setSecret(value, for: expected)
            }
        }
        if changed { _ = try await session.saveEnvironment(normalized, key: savedKey) }
    }

    func deleteEnvironment(key: String, in collectionID: UUID) async {
        guard let session = collection(collectionID)?.session else { return }
        if activeEnvironmentKeys[collectionID] == key { setActiveEnvironment(nil, for: collectionID) }
        for variable in environments(for: collectionID).first(where: { $0.key == key })?.environment.variables ?? [] {
            if case .secret(let reference) = variable.value {
                try? await environment.secrets.deleteSecret(for: reference)
            }
        }
        await perform(reloading: collectionID) { try await session.deleteEnvironment(key: key) }
    }

    /// Reads a secret for display after device-owner authentication (F04.5).
    func revealSecret(_ reference: SecretRef) async -> String? {
        do {
            try await environment.authenticator.authenticate(reason: String(localized: "Reveal the secret value"))
            return try await environment.secrets.secret(for: reference)
        } catch {
            present(error)
            return nil
        }
    }

    func reloadGlobals() async {
        if let stored = try? await environment.store.environments(for: nil).first { globals = stored }
    }

    func saveGlobals(_ updated: Environment, secretValues: [String: String]) async {
        var normalized = updated
        normalized.id = globals.id
        do {
            for index in normalized.variables.indices {
                guard case .secret = normalized.variables[index].value else { continue }
                let reference = SecretRef.environmentVariable(
                    environmentKey: "globals", name: normalized.variables[index].name)
                normalized.variables[index].value = .secret(reference)
                if let value = secretValues[normalized.variables[index].name] {
                    try await environment.secrets.setSecret(value, for: reference)
                }
            }
            try await environment.store.upsertEnvironment(normalized, for: nil)
            globals = normalized
        } catch {
            present(error)
        }
    }

    // MARK: Sending (F01, P05)

    /// Sends a request. `reference` is nil for unsaved scratch requests (no collection context).
    func send(_ request: RequestItem, reference: RequestReference?) async throws(SendError) -> SendResult {
        let collectionID = reference?.collectionID
        let context = sendContext(
            collectionID: collectionID, folderKey: reference.flatMap { self.request($0)?.folderKey })
        var effective = applyingDefaults(to: request)
        if !gate.isPro {
            // Free tier: extraction and assertions are Pro (P05, P06); they don't run.
            effective.extractors = []
            effective.assertions = []
        }
        let result = try await environment.executor.send(effective, context: context)
        if let collectionID {
            runtimeVariables[collectionID] = result.runtimeVariables
            if !result.variablesToPersist.isEmpty { await persist(result.variablesToPersist, in: collectionID) }
        }
        if (200..<400).contains(result.response.statusCode) { preferences.successfulRequestCount += 1 }
        await reloadHistory()
        return result
    }

    /// Uses the default timeout from Settings when the request doesn't set its own (F01.6).
    func applyingDefaults(to request: RequestItem) -> RequestItem {
        var effective = request
        if (effective.settings.timeoutMilliseconds ?? 0) <= 0 {
            effective.settings.timeoutMilliseconds = preferences.defaultTimeoutSeconds * 1000
        }
        return effective
    }

    /// Folders, environment, globals, runtime variables, cookies and files for sending in a collection.
    func sendContext(collectionID: UUID?, folderKey: String?) -> SendContext {
        let state = collectionID.flatMap(collection)
        var context = SendContext(
            folders: state?.tree?.folderChain(to: folderKey) ?? [],
            collection: state?.tree?.settings ?? FolderSettings(),
            environment: collectionID.flatMap { activeEnvironment(for: $0)?.environment }, globals: globals,
            runtimeVariables: collectionID.flatMap { runtimeVariables[$0] } ?? [:],
            useCookieJar: gate.isPro && (state?.summary.useCookieJar ?? true), recordHistory: true,
            historyLimit: gate.historyLimit)
        context.files =
            state?.session?.files ?? BookmarkFileResolver(baseDirectory: nil, folderAccess: environment.folderAccess)
        return context
    }

    /// Writes extracted values into the active environment (P05.1).
    private func persist(_ values: [String: String], in collectionID: UUID) async {
        guard let active = activeEnvironment(for: collectionID) else { return }
        var environment = active.environment
        for (name, value) in values {
            if let index = environment.variables.firstIndex(where: { $0.name == name }) {
                if case .plain = environment.variables[index].value {
                    environment.variables[index].value = .plain(value)
                }
            } else {
                environment.variables.append(.plain(name, value))
            }
        }
        _ = await saveEnvironment(environment, key: active.key, in: collectionID, secretValues: [:])
    }

    func clearRuntimeVariables(for collectionID: UUID) { runtimeVariables[collectionID] = nil }

    /// Substitutes variables (including Keychain secrets) in an OAuth configuration, as the executor does.
    func resolvedOAuthConfig(_ config: OAuth2Config, context: VariableContext) async -> OAuth2Config {
        let references = context.scopes.flatMap(\.values.values).compactMap { value -> SecretRef? in
            if case .secret(let reference) = value { return reference }
            return nil
        }
        let snapshot = (try? await environment.secrets.snapshot(for: references)) ?? SecretSnapshot()
        return RequestExecutor.interpolate(
            config, interpolator: Interpolator(secretResolver: snapshot.resolver), context: context)
    }

    // MARK: History (F06)

    func reloadHistory() async {
        history = (try? await environment.store.history(limit: gate.historyLimit)) ?? []
    }

    func clearHistory() async {
        await perform { try await self.environment.store.clearHistory() }
        await reloadHistory()
    }

    func deleteHistoryEntry(_ id: UUID) async {
        await perform { try await self.environment.store.deleteHistoryEntry(id) }
        await reloadHistory()
    }

    // MARK: Imports (F07, P02, P03)

    /// Creates a native collection from an imported document (OpenAPI/Postman). Returns its id.
    func importCollection(_ imported: ImportedCollection) async -> UUID? {
        guard require(gate.canCreateCollection(existingNonSampleCount: userCollections.count)) else { return nil }
        do {
            let summary = try await environment.store.createCollection(
                name: imported.name, storage: .native, settings: imported.settings)
            var folderIDs: [String: UUID] = [:]
            for (offset, folder) in imported.folders.enumerated() {
                let parentPath =
                    folder.path.contains("/")
                    ? String(folder.path[..<(folder.path.lastIndex(of: "/") ?? folder.path.startIndex)]) : nil
                let stored = RequestFolder(name: folder.name, path: folder.path, settings: folder.settings)
                try await environment.store.upsertFolder(
                    stored, parentID: parentPath.flatMap { folderIDs[$0] }, in: summary.id, sortOrder: offset)
                folderIDs[folder.path] = stored.id
            }
            for item in imported.items {
                try await environment.store.upsertRequest(
                    item.request, folderID: item.folderPath.flatMap { folderIDs[$0] }, in: summary.id)
            }
            for (offset, environment) in imported.environments.enumerated() {
                try await self.environment.store.upsertEnvironment(environment, for: summary.id, sortOrder: offset)
            }
            await reloadCollections()
            return summary.id
        } catch {
            present(error)
            return nil
        }
    }

    // MARK: Local Echo and sample data (F08)

    func startEcho() async {
        do {
            echoPort = try await environment.echo.start()
            preferences.localEchoEnabled = true
            await setGlobal(SampleData.echoVariable, value: await environment.echo.baseURL?.absoluteString ?? "")
        } catch {
            present(error)
        }
    }

    func stopEcho() async {
        await environment.echo.stop()
        echoPort = nil
        preferences.localEchoEnabled = false
    }

    private func setGlobal(_ name: String, value: String) async {
        var updated = globals
        updated.variables.removeAll { $0.name == name }
        updated.variables.append(.plain(name, value))
        await saveGlobals(updated, secretValues: [:])
    }

    func loadSampleData() async {
        await startEcho()
        guard let base = await environment.echo.baseURL else { return }
        do {
            try await SampleData.install(into: environment.store, echoBaseURL: base)
            await reloadCollections()
            await reloadGlobals()
            setActiveEnvironment(SampleData.environmentID.uuidString, for: SampleData.collectionID)
        } catch {
            present(error)
        }
    }

    // MARK: Onboarding, data control (X02, X04)

    func completeOnboarding() {
        preferences.onboardingCompleted = true
        onboardingCompleted = true
    }

    func eraseAllData() async {
        await stopEcho()
        for state in collections { await state.session?.close() }
        watchTasks.values.forEach { $0.cancel() }
        watchTasks.removeAll()
        do {
            try await environment.eraser.eraseAll()
        } catch {
            present(error)
        }
        collections = []
        runtimeVariables = [:]
        activeEnvironmentKeys = [:]
        history = []
        globals = Environment(id: SampleData.globalsID, name: String(localized: "Globals"))
        onboardingCompleted = false
        appearance = preferences.appearance
    }

    func exportAppData() async -> Data? {
        do {
            return try await environment.transfer.exportData()
        } catch {
            present(error)
            return nil
        }
    }

    func importAppData(_ data: Data) async {
        do {
            try await environment.transfer.importData(data)
            await reloadCollections()
            await reloadGlobals()
        } catch {
            present(error)
        }
    }

    // MARK: Helpers

    func present(_ error: some LocalizedError) {
        show(error)
    }

    /// Presents errors from untyped throwing code; non-localized errors get a generic message.
    func present(_ error: any Error) {
        if let localized = error as? any LocalizedError {
            show(localized)
        } else {
            show(UnexpectedError(description: String(describing: error)))
        }
    }

    private func show(_ error: some LocalizedError) {
        log.error("\(String(describing: error), privacy: .private)")
        presentedError = PresentedError(error)
    }

    private func perform(reloading collectionID: UUID? = nil, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            present(error)
        }
        if let collectionID {
            await reloadTree(collectionID)
        } else {
            await reloadCollections()
        }
    }

    private func purgeTemporaryBodies() {
        let directory = environment.locations.responseBodiesDirectory
        for item in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        {
            try? FileManager.default.removeItem(at: item)
        }
    }
}

/// Wraps an error without a user-facing description.
struct UnexpectedError: LocalizedError {
    let description: String
    var errorDescription: String? { String(localized: "Something went wrong") }
    var recoverySuggestion: String? {
        String(localized: "Please try again. If it keeps happening, contact support from Settings.")
    }
}
