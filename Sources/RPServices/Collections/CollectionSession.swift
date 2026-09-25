import Foundation
import RPCore
import RPData

/// A collection's contents in one shape for both storage kinds. Keys are stable per storage: UUID strings for
/// native collections, relative file paths for folder collections.
public struct CollectionTree: Sendable, Hashable {
    public struct Folder: Sendable, Hashable, Identifiable {
        public var key: String
        public var parentKey: String?
        public var name: String
        public var settings: FolderSettings
        public var sortOrder: Int
        public var id: String { key }
    }

    public struct Request: Sendable, Hashable, Identifiable {
        public var key: String
        public var folderKey: String?
        public var request: RequestItem
        public var id: String { key }
    }

    public struct EnvironmentEntry: Sendable, Hashable, Identifiable {
        public var key: String
        public var environment: Environment
        public var id: String { key }
    }

    public var id: UUID
    public var name: String
    public var storage: CollectionStorage
    public var settings: FolderSettings
    public var folders: [Folder]
    public var requests: [Request]
    public var environments: [EnvironmentEntry]
    /// Files that couldn't be read (folder collections), shown in the sidebar.
    public var issues: [String]
    public var hasUnsupportedScripts: Bool

    public func children(of folderKey: String?) -> (folders: [Folder], requests: [Request]) {
        (
            folders.filter { $0.parentKey == folderKey }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) },
            requests.filter { $0.folderKey == folderKey }.sorted {
                ($0.request.sortOrder, $0.request.name) < ($1.request.sortOrder, $1.request.name)
            }
        )
    }

    /// Folder settings from the outermost folder to `folderKey` (for header/auth/variable inheritance).
    public func folderChain(to folderKey: String?) -> [FolderSettings] {
        var chain: [FolderSettings] = []
        var visited: Set<String> = []
        var current = folderKey
        while let key = current, visited.insert(key).inserted, let folder = folders.first(where: { $0.key == key }) {
            chain.insert(folder.settings, at: 0)
            current = folder.parentKey
        }
        return chain
    }

    /// `Folder/Sub/Name` for display in runner results and history.
    public func displayPath(of requestKey: String) -> String {
        guard let entry = requests.first(where: { $0.key == requestKey }) else { return "" }
        var components = [entry.request.name]
        var visited: Set<String> = []
        var current = entry.folderKey
        while let key = current, visited.insert(key).inserted, let folder = folders.first(where: { $0.key == key }) {
            components.insert(folder.name, at: 0)
            current = folder.parentKey
        }
        return components.joined(separator: "/")
    }

    /// Requests in a folder and its subfolders, in tree order (collection runner, P06.2). `nil` means everything.
    public func requestsInOrder(under folderKey: String?) -> [Request] {
        var result: [Request] = []
        func visit(_ key: String?, depth: Int) {
            guard depth < 64 else { return }
            let children = children(of: key)
            result.append(contentsOf: children.requests)
            for folder in children.folders { visit(folder.key, depth: depth + 1) }
        }
        visit(folderKey, depth: 0)
        return result
    }
}

/// Reading and editing one collection, whatever its storage (F03, P01).
public protocol CollectionSession: Sendable {
    var id: UUID { get }
    var storage: CollectionStorage { get }
    /// Resolves multipart file references for this collection.
    var files: any FileReferenceResolver { get }

    func load() async throws(DataError) -> CollectionTree
    /// Saves a request and returns its key (new requests get one).
    func saveRequest(_ request: RequestItem, key: String?, folderKey: String?, overwrite: Bool) async throws(DataError)
        -> String
    func renameRequest(_ request: RequestItem, key: String, to name: String) async throws(DataError) -> String
    func moveRequest(key: String, toFolder folderKey: String?, position: Int) async throws(DataError) -> String
    func deleteRequest(key: String) async throws(DataError)
    func createFolder(named name: String, parentKey: String?) async throws(DataError) -> String
    func renameFolder(key: String, to name: String) async throws(DataError) -> String
    func deleteFolder(key: String) async throws(DataError)
    func saveFolderSettings(_ settings: FolderSettings, key: String) async throws(DataError)
    func saveCollectionSettings(_ settings: FolderSettings) async throws(DataError)
    func saveEnvironment(_ environment: Environment, key: String?) async throws(DataError) -> String
    func deleteEnvironment(key: String) async throws(DataError)
    /// Keychain `environmentKey` for secret variables of an environment.
    func secretKey(forEnvironment key: String) -> String
    /// Signals changes made outside RequestPad (folder collections); finishes immediately for native ones.
    func externalChanges() -> AsyncStream<Void>
    func close() async
}

/// A native (or sample) collection stored in the app's database.
public actor NativeCollectionSession: CollectionSession {
    public nonisolated let id: UUID
    public nonisolated let storage: CollectionStorage
    public nonisolated let files: any FileReferenceResolver
    private let store: LocalStore

    public init(
        id: UUID, storage: CollectionStorage, store: LocalStore,
        files: any FileReferenceResolver = BookmarkFileResolver(
            baseDirectory: nil, folderAccess: SecurityScopedBookmarks())
    ) {
        self.id = id
        self.storage = storage
        self.store = store
        self.files = files
    }

    public func load() async throws(DataError) -> CollectionTree {
        let collection = try await store.nativeCollection(id)
        let environments = try await store.environments(for: id)
        return CollectionTree(
            id: id, name: collection.summary.name, storage: collection.summary.storage, settings: collection.settings,
            folders: collection.folders.map {
                .init(
                    key: $0.id.uuidString, parentKey: $0.parentID?.uuidString, name: $0.folder.name,
                    settings: $0.folder.settings, sortOrder: $0.sortOrder)
            },
            requests: collection.requests.map {
                .init(key: $0.id.uuidString, folderKey: $0.folderID?.uuidString, request: $0.request)
            },
            environments: environments.map { .init(key: $0.id.uuidString, environment: $0) }, issues: [],
            hasUnsupportedScripts: collection.requests.contains { $0.request.hasUnsupportedScripts })
    }

    public func saveRequest(_ request: RequestItem, key: String?, folderKey: String?, overwrite: Bool)
        async throws(DataError) -> String
    {
        var item = request
        if let key, let uuid = UUID(uuidString: key) { item.id = uuid }
        try await store.upsertRequest(item, folderID: folderKey.flatMap(UUID.init(uuidString:)), in: id)
        return item.id.uuidString
    }

    public func renameRequest(_ request: RequestItem, key: String, to name: String) async throws(DataError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidName(name) }
        let stored = try await store.request(try uuid(key))
        var renamed = stored.request
        renamed.name = trimmed
        return try await saveRequest(renamed, key: key, folderKey: stored.folderID?.uuidString, overwrite: true)
    }

    public func moveRequest(key: String, toFolder folderKey: String?, position: Int) async throws(DataError) -> String {
        try await store.moveRequest(try uuid(key), toFolder: folderKey.flatMap(UUID.init(uuidString:)), at: position)
        return key
    }

    public func deleteRequest(key: String) async throws(DataError) {
        try await store.deleteRequest(try uuid(key))
    }

    public func createFolder(named name: String, parentKey: String?) async throws(DataError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidName(name) }
        let tree = try await load()
        let order = (tree.children(of: parentKey).folders.map(\.sortOrder).max() ?? 0) + 1
        let folder = RequestFolder(name: trimmed, path: trimmed)
        try await store.upsertFolder(
            folder, parentID: parentKey.flatMap(UUID.init(uuidString:)), in: id, sortOrder: order)
        return folder.id.uuidString
    }

    public func renameFolder(key: String, to name: String) async throws(DataError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidName(name) }
        let tree = try await load()
        guard let folder = tree.folders.first(where: { $0.key == key }) else { throw .notFound(what: "folder") }
        try await store.upsertFolder(
            RequestFolder(id: try uuid(key), name: trimmed, path: trimmed, settings: folder.settings),
            parentID: folder.parentKey.flatMap(UUID.init(uuidString:)), in: id)
        return key
    }

    public func deleteFolder(key: String) async throws(DataError) {
        try await store.deleteFolder(try uuid(key))
    }

    public func saveFolderSettings(_ settings: FolderSettings, key: String) async throws(DataError) {
        let tree = try await load()
        guard let folder = tree.folders.first(where: { $0.key == key }) else { throw .notFound(what: "folder") }
        try await store.upsertFolder(
            RequestFolder(id: try uuid(key), name: folder.name, path: folder.name, settings: settings),
            parentID: folder.parentKey.flatMap(UUID.init(uuidString:)), in: id)
    }

    public func saveCollectionSettings(_ settings: FolderSettings) async throws(DataError) {
        try await store.updateCollectionSettings(id, settings: settings)
    }

    public func saveEnvironment(_ environment: Environment, key: String?) async throws(DataError) -> String {
        var item = environment
        if let key, let uuid = UUID(uuidString: key) { item.id = uuid }
        try await store.upsertEnvironment(item, for: id)
        return item.id.uuidString
    }

    public func deleteEnvironment(key: String) async throws(DataError) {
        try await store.deleteEnvironment(try uuid(key))
    }

    public nonisolated func secretKey(forEnvironment key: String) -> String { key }

    public nonisolated func externalChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    public func close() async {}

    private func uuid(_ key: String) throws(DataError) -> UUID {
        guard let value = UUID(uuidString: key) else { throw .notFound(what: "item") }
        return value
    }
}

/// A Bruno collection folder (P01). Holds security-scoped access for the session's lifetime.
public actor FolderCollectionSession: CollectionSession {
    public nonisolated let id: UUID
    public nonisolated let storage: CollectionStorage = .folder
    public nonisolated let files: any FileReferenceResolver
    public nonisolated let root: URL
    private let repository: FolderCollectionRepository
    private let access: ScopedAccess
    private let watcher: FolderWatcher

    /// Resolves `bookmark` and starts access. Stale bookmarks are refreshed through `refreshBookmark`.
    public init(
        id: UUID, bookmark: Data, folderAccess: any FolderAccess, refreshBookmark: @Sendable (Data) async -> Void
    ) async throws(DataError) {
        let resolved = try folderAccess.resolve(bookmark)
        let access = folderAccess.beginAccess(to: resolved.url)
        if resolved.isStale, let fresh = try? folderAccess.makeBookmark(for: resolved.url) {
            await refreshBookmark(fresh)
        }
        guard FileManager.default.isReadableFile(atPath: resolved.url.path(percentEncoded: false)) else {
            access.stop()
            throw .accessDenied(path: resolved.url.lastPathComponent)
        }
        self.id = id
        root = resolved.url
        self.access = access
        repository = FolderCollectionRepository(root: resolved.url, collectionKey: id.uuidString)
        watcher = FolderWatcher(root: resolved.url)
        files = BookmarkFileResolver(baseDirectory: resolved.url, folderAccess: folderAccess)
    }

    public func load() async throws(DataError) -> CollectionTree {
        let snapshot = try await repository.load()
        return CollectionTree(
            id: id, name: snapshot.name, storage: .folder, settings: snapshot.settings,
            folders: snapshot.folders.map { folder in
                let parent =
                    folder.path.contains("/")
                    ? String(folder.path[..<(folder.path.lastIndex(of: "/") ?? folder.path.startIndex)]) : nil
                return .init(
                    key: folder.path, parentKey: parent, name: folder.name, settings: folder.settings,
                    sortOrder: folder.settings.sequence ?? Int.max)
            },
            requests: snapshot.requests.map { .init(key: $0.path, folderKey: $0.folderPath, request: $0.request) },
            environments: snapshot.environments.map { .init(key: $0.fileName, environment: $0.environment) },
            issues: snapshot.issues.map { "\($0.path): \($0.message)" },
            hasUnsupportedScripts: snapshot.hasUnsupportedScripts
                || snapshot.requests.contains { $0.request.hasUnsupportedScripts })
    }

    public func saveRequest(_ request: RequestItem, key: String?, folderKey: String?, overwrite: Bool)
        async throws(DataError) -> String
    {
        try await repository.saveRequest(request, at: key, inFolder: folderKey, overwrite: overwrite)
    }

    public func renameRequest(_ request: RequestItem, key: String, to name: String) async throws(DataError) -> String {
        try await repository.renameRequest(request, at: key, to: name)
    }

    public func moveRequest(key: String, toFolder folderKey: String?, position: Int) async throws(DataError) -> String {
        let currentFolder = key.contains("/") ? String(key[..<(key.lastIndex(of: "/") ?? key.startIndex)]) : nil
        guard currentFolder != folderKey else { return key }
        return try await repository.moveRequest(at: key, toFolder: folderKey)
    }

    public func deleteRequest(key: String) async throws(DataError) {
        try await repository.deleteRequest(at: key)
    }

    public func createFolder(named name: String, parentKey: String?) async throws(DataError) -> String {
        try await repository.createFolder(named: name, in: parentKey)
    }

    public func renameFolder(key: String, to name: String) async throws(DataError) -> String {
        try await repository.renameFolder(at: key, to: name)
    }

    public func deleteFolder(key: String) async throws(DataError) {
        try await repository.deleteFolder(at: key)
    }

    public func saveFolderSettings(_ settings: FolderSettings, key: String) async throws(DataError) {
        let name = String(key.split(separator: "/").last ?? Substring(key))
        try await repository.saveFolderSettings(settings, name: name, at: key, overwrite: true)
    }

    public func saveCollectionSettings(_ settings: FolderSettings) async throws(DataError) {
        try await repository.saveCollectionSettings(settings, overwrite: true)
    }

    public func saveEnvironment(_ environment: Environment, key: String?) async throws(DataError) -> String {
        try await repository.saveEnvironment(environment, fileName: key, overwrite: true)
    }

    public func deleteEnvironment(key: String) async throws(DataError) {
        try await repository.deleteEnvironment(fileName: key)
    }

    public nonisolated func secretKey(forEnvironment key: String) -> String { repository.environmentKey(for: key) }

    /// Debounced change events filtered to real external edits (RequestPad's own writes don't count).
    public nonisolated func externalChanges() -> AsyncStream<Void> {
        let events = watcher.events()
        let repository = repository
        return AsyncStream { continuation in
            let task = Task {
                for await _ in events where await repository.hasExternalChanges() {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() async {
        watcher.stop()
        access.stop()
    }
}
