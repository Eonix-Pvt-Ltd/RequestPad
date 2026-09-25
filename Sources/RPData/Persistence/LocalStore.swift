import Foundation
import RPCore
import SwiftData

/// Summary of a collection for the sidebar.
public struct CollectionSummary: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var storage: CollectionStorage
    public var bookmark: Data?
    public var sortOrder: Int
    public var useCookieJar: Bool
    public var createdAt: Date

    public init(
        id: UUID, name: String, storage: CollectionStorage, bookmark: Data? = nil, sortOrder: Int = 0,
        useCookieJar: Bool = true, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.storage = storage
        self.bookmark = bookmark
        self.sortOrder = sortOrder
        self.useCookieJar = useCookieJar
        self.createdAt = createdAt
    }
}

/// A request stored in a native collection, with its folder.
public struct StoredRequest: Hashable, Sendable, Identifiable {
    public var request: RequestItem
    public var folderID: UUID?
    public var id: UUID { request.id }

    public init(request: RequestItem, folderID: UUID?) {
        self.request = request
        self.folderID = folderID
    }
}

/// A folder in a native collection. `path` in ``RPCore/RequestFolder`` is derived from the parent chain.
public struct StoredFolder: Hashable, Sendable, Identifiable {
    public var folder: RequestFolder
    public var parentID: UUID?
    public var sortOrder: Int
    public var id: UUID { folder.id }

    public init(folder: RequestFolder, parentID: UUID?, sortOrder: Int = 0) {
        self.folder = folder
        self.parentID = parentID
        self.sortOrder = sortOrder
    }
}

/// The full contents of a native (or sample) collection.
public struct NativeCollection: Hashable, Sendable {
    public var summary: CollectionSummary
    public var settings: FolderSettings
    public var folders: [StoredFolder]
    public var requests: [StoredRequest]
}

/// The app's database. All reads and writes run on this actor; callers exchange Sendable RPCore values only.
/// Every repeated write is an upsert by natural key (B5): fetch by key, update or insert, save once.
@ModelActor
public actor LocalStore {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    // MARK: Collections

    public func collections() throws(DataError) -> [CollectionSummary] {
        try fetch(
            FetchDescriptor<CollectionRecord>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        )
        .compactMap(summary(from:))
    }

    /// Creates a collection. `id` may be given (sample collection, imports) to keep keys stable.
    @discardableResult
    public func createCollection(
        name: String, storage: CollectionStorage, bookmark: Data? = nil, settings: FolderSettings = FolderSettings(),
        id: UUID = UUID(), now: Date = Date()
    ) throws(DataError) -> CollectionSummary {
        let key = id.uuidString
        let record =
            try first(CollectionRecord.self, #Predicate { $0.key == key })
            ?? {
                let created = CollectionRecord(key: key)
                modelContext.insert(created)
                return created
            }()
        record.name = name
        record.kind = storage.rawValue
        record.bookmark = bookmark
        record.settingsJSON = try encode(settings, what: "collection settings")
        record.sortOrder = try nextCollectionOrder(excluding: key)
        record.createdAt = now
        try save()
        return CollectionSummary(
            id: id, name: name, storage: storage, bookmark: bookmark, sortOrder: record.sortOrder, createdAt: now)
    }

    public func renameCollection(_ id: UUID, to name: String) throws(DataError) {
        try collectionRecord(id).name = name
        try save()
    }

    public func updateCollectionBookmark(_ id: UUID, bookmark: Data) throws(DataError) {
        try collectionRecord(id).bookmark = bookmark
        try save()
    }

    public func setCookieJarEnabled(_ enabled: Bool, for id: UUID) throws(DataError) {
        try collectionRecord(id).useCookieJar = enabled
        try save()
    }

    public func updateCollectionSettings(_ id: UUID, settings: FolderSettings) throws(DataError) {
        try collectionRecord(id).settingsJSON = try encode(settings, what: "collection settings")
        try save()
    }

    /// Reorders collections to match `ids` (sidebar drag and drop).
    public func reorderCollections(_ ids: [UUID]) throws(DataError) {
        for (offset, id) in ids.enumerated() { try collectionRecord(id).sortOrder = offset }
        try save()
    }

    /// Deletes a collection with its folders, requests and environments (folder files on disk are untouched).
    public func deleteCollection(_ id: UUID) throws(DataError) {
        let key = id.uuidString
        try deleteAll(CollectionRecord.self, #Predicate { $0.key == key })
        try deleteAll(FolderRecord.self, #Predicate { $0.collectionKey == key })
        try deleteAll(RequestRecord.self, #Predicate { $0.collectionKey == key })
        try deleteAll(EnvironmentRecord.self, #Predicate { $0.collectionKey == key })
        try save()
    }

    public func nativeCollection(_ id: UUID) throws(DataError) -> NativeCollection {
        let record = try collectionRecord(id)
        guard let summary = summary(from: record) else { throw .notFound(what: "collection") }
        let key = id.uuidString
        let folderRecords = try fetch(
            FetchDescriptor<FolderRecord>(
                predicate: #Predicate { $0.collectionKey == key }, sortBy: [SortDescriptor(\.sortOrder)]))
        let requests = try fetch(
            FetchDescriptor<RequestRecord>(
                predicate: #Predicate { $0.collectionKey == key }, sortBy: [SortDescriptor(\.sortOrder)])
        ).compactMap { record -> StoredRequest? in
            guard let data = record.itemJSON, let item = try? decoder.decode(RequestItem.self, from: data) else {
                return nil
            }
            return StoredRequest(request: item, folderID: record.folderKey.flatMap(UUID.init(uuidString:)))
        }
        let settings =
            record.settingsJSON.flatMap { try? decoder.decode(FolderSettings.self, from: $0) } ?? FolderSettings()
        return NativeCollection(
            summary: summary, settings: settings, folders: folders(from: folderRecords), requests: requests)
    }

    /// Number of requests in a collection (free-tier limit, F03.2).
    public func requestCount(in id: UUID) throws(DataError) -> Int {
        let key = id.uuidString
        return try count(RequestRecord.self, #Predicate { $0.collectionKey == key })
    }

    // MARK: Folders

    @discardableResult
    public func upsertFolder(
        _ folder: RequestFolder, parentID: UUID?, in collectionID: UUID, sortOrder: Int? = nil
    ) throws(DataError) -> StoredFolder {
        _ = try collectionRecord(collectionID)
        let key = folder.id.uuidString
        let record =
            try first(FolderRecord.self, #Predicate { $0.key == key })
            ?? {
                let created = FolderRecord(key: key)
                modelContext.insert(created)
                return created
            }()
        record.collectionKey = collectionID.uuidString
        record.parentKey = parentID?.uuidString
        record.name = folder.name
        record.settingsJSON = try encode(folder.settings, what: "folder settings")
        if let sortOrder { record.sortOrder = sortOrder }
        try save()
        return StoredFolder(folder: folder, parentID: parentID, sortOrder: record.sortOrder)
    }

    /// Deletes a folder, its subfolders and every request inside them.
    public func deleteFolder(_ id: UUID) throws(DataError) {
        var pending = [id.uuidString]
        while let key = pending.popLast() {
            let children = try fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.parentKey == key })).map(
                \.key)
            pending.append(contentsOf: children)
            try deleteAll(RequestRecord.self, #Predicate { $0.folderKey == key })
            try deleteAll(FolderRecord.self, #Predicate { $0.key == key })
        }
        try save()
    }

    // MARK: Requests

    public func upsertRequest(
        _ request: RequestItem, folderID: UUID?, in collectionID: UUID, now: Date = Date()
    ) throws(DataError) {
        _ = try collectionRecord(collectionID)
        let key = request.id.uuidString
        let record =
            try first(RequestRecord.self, #Predicate { $0.key == key })
            ?? {
                let created = RequestRecord(key: key)
                modelContext.insert(created)
                return created
            }()
        record.collectionKey = collectionID.uuidString
        record.folderKey = folderID?.uuidString
        record.sortOrder = request.sortOrder
        record.name = request.name
        record.method = request.method.rawValue
        record.url = request.url
        record.itemJSON = try encode(request, what: "request")
        record.updatedAt = now
        try save()
    }

    public func request(_ id: UUID) throws(DataError) -> StoredRequest {
        let key = id.uuidString
        guard let record = try first(RequestRecord.self, #Predicate { $0.key == key }), let data = record.itemJSON,
            let item = try? decoder.decode(RequestItem.self, from: data)
        else { throw .notFound(what: "request") }
        return StoredRequest(request: item, folderID: record.folderKey.flatMap(UUID.init(uuidString:)))
    }

    public func deleteRequest(_ id: UUID) throws(DataError) {
        let key = id.uuidString
        try deleteAll(RequestRecord.self, #Predicate { $0.key == key })
        try save()
    }

    /// Moves a request to another folder (or the root) and position, renumbering siblings (F03.1).
    public func moveRequest(_ id: UUID, toFolder folderID: UUID?, at position: Int) throws(DataError) {
        let key = id.uuidString
        guard let moving = try first(RequestRecord.self, #Predicate { $0.key == key }) else {
            throw .notFound(what: "request")
        }
        let collectionKey = moving.collectionKey
        let targetFolder = folderID?.uuidString
        var siblings = try fetch(
            FetchDescriptor<RequestRecord>(
                predicate: #Predicate {
                    $0.collectionKey == collectionKey && $0.folderKey == targetFolder && $0.key != key
                },
                sortBy: [SortDescriptor(\.sortOrder)]))
        siblings.insert(moving, at: min(max(position, 0), siblings.count))
        moving.folderKey = targetFolder
        for (offset, record) in siblings.enumerated() {
            record.sortOrder = offset + 1
            if let data = record.itemJSON, var item = try? decoder.decode(RequestItem.self, from: data) {
                item.sortOrder = offset + 1
                record.itemJSON = try encode(item, what: "request")
            }
        }
        try save()
    }

    /// Case-insensitive search over request name, method and URL across native collections (F03.4).
    public func searchRequests(_ text: String, limit: Int = 200) throws(DataError) -> [StoredRequest] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var descriptor = FetchDescriptor<RequestRecord>(
            predicate: #Predicate {
                $0.name.localizedStandardContains(query) || $0.url.localizedStandardContains(query)
                    || $0.method.localizedStandardContains(query)
            }, sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = limit
        return try fetch(descriptor).compactMap { record in
            guard let data = record.itemJSON, let item = try? decoder.decode(RequestItem.self, from: data) else {
                return nil
            }
            return StoredRequest(request: item, folderID: record.folderKey.flatMap(UUID.init(uuidString:)))
        }
    }

    // MARK: Environments

    /// Environments of a collection, or the globals when `collectionID` is nil.
    public func environments(for collectionID: UUID?) throws(DataError) -> [Environment] {
        let key = collectionID?.uuidString
        return try fetch(
            FetchDescriptor<EnvironmentRecord>(
                predicate: #Predicate { $0.collectionKey == key }, sortBy: [SortDescriptor(\.sortOrder)])
        ).compactMap { record in
            guard let id = UUID(uuidString: record.key) else { return nil }
            let variables = record.variablesJSON.flatMap { try? decoder.decode([Variable].self, from: $0) } ?? []
            return Environment(id: id, name: record.name, variables: variables)
        }
    }

    public func upsertEnvironment(_ environment: Environment, for collectionID: UUID?, sortOrder: Int? = nil)
        throws(DataError)
    {
        let key = environment.id.uuidString
        let record =
            try first(EnvironmentRecord.self, #Predicate { $0.key == key })
            ?? {
                let created = EnvironmentRecord(key: key)
                modelContext.insert(created)
                return created
            }()
        record.collectionKey = collectionID?.uuidString
        record.name = environment.name
        if let sortOrder { record.sortOrder = sortOrder }
        record.variablesJSON = try encode(environment.variables, what: "environment")
        try save()
    }

    public func deleteEnvironment(_ id: UUID) throws(DataError) {
        let key = id.uuidString
        try deleteAll(EnvironmentRecord.self, #Predicate { $0.key == key })
        try save()
    }

    // MARK: History (F06)

    /// Records a sent request and prunes the oldest entries beyond `limit`.
    public func appendHistory(_ entry: HistoryEntry, limit: Int) throws(DataError) {
        let key = entry.id.uuidString
        let record =
            try first(HistoryRecord.self, #Predicate { $0.key == key })
            ?? {
                let created = HistoryRecord(key: key)
                modelContext.insert(created)
                return created
            }()
        record.sentAt = entry.sentAt
        record.name = entry.request.name
        record.method = entry.request.method.rawValue
        record.url = entry.request.url
        record.statusCode = entry.response.statusCode
        record.entryJSON = try encode(entry, what: "history entry")
        try pruneHistory(to: limit)
        try save()
    }

    public func pruneHistory(to limit: Int) throws(DataError) {
        let total = try count(HistoryRecord.self, nil)
        guard total > limit else { return }
        var descriptor = FetchDescriptor<HistoryRecord>(sortBy: [SortDescriptor(\.sentAt, order: .forward)])
        descriptor.fetchLimit = total - max(limit, 0)
        for record in try fetch(descriptor) { modelContext.delete(record) }
        try save()
    }

    /// Newest first, optionally filtered by name/URL/method.
    public func history(matching text: String = "", limit: Int = 1_000) throws(DataError) -> [HistoryEntry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        var descriptor: FetchDescriptor<HistoryRecord>
        if query.isEmpty {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\.sentAt, order: .reverse)])
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.name.localizedStandardContains(query) || $0.url.localizedStandardContains(query)
                        || $0.method.localizedStandardContains(query)
                }, sortBy: [SortDescriptor(\.sentAt, order: .reverse)])
        }
        descriptor.fetchLimit = limit
        return try fetch(descriptor).compactMap { record in
            record.entryJSON.flatMap { try? decoder.decode(HistoryEntry.self, from: $0) }
        }
    }

    public func deleteHistoryEntry(_ id: UUID) throws(DataError) {
        let key = id.uuidString
        try deleteAll(HistoryRecord.self, #Predicate { $0.key == key })
        try save()
    }

    public func clearHistory() throws(DataError) {
        try deleteAll(HistoryRecord.self, nil)
        try save()
    }

    // MARK: Cookies (P07)

    public func cookieJar() throws(DataError) -> CookieJar {
        CookieJar(
            cookies: try fetch(FetchDescriptor<CookieRecord>()).compactMap { record in
                record.cookieJSON.flatMap { try? decoder.decode(Cookie.self, from: $0) }
            })
    }

    /// Replaces the stored jar with `jar` (upserting by cookie identity, deleting removed cookies).
    public func saveCookieJar(_ jar: CookieJar) throws(DataError) {
        let wanted = Dictionary(jar.cookies.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for record in try fetch(FetchDescriptor<CookieRecord>()) where wanted[record.key] == nil {
            modelContext.delete(record)
        }
        for (key, cookie) in wanted {
            let record =
                try first(CookieRecord.self, #Predicate { $0.key == key })
                ?? {
                    let created = CookieRecord(key: key)
                    modelContext.insert(created)
                    return created
                }()
            record.domain = cookie.domain
            record.cookieJSON = try encode(cookie, what: "cookie")
        }
        try save()
    }

    // MARK: GraphQL schema cache (P04.2)

    public func cachedSchema(for endpoint: String) throws(DataError) -> (schema: GraphQLSchema, fetchedAt: Date)? {
        let key = endpoint
        guard let record = try first(SchemaCacheRecord.self, #Predicate { $0.key == key }),
            let data = record.schemaJSON,
            let schema = try? decoder.decode(GraphQLSchema.self, from: data)
        else { return nil }
        return (schema, record.fetchedAt)
    }

    public func cacheSchema(_ schema: GraphQLSchema, for endpoint: String, fetchedAt: Date) throws(DataError) {
        let key = endpoint
        let record =
            try first(SchemaCacheRecord.self, #Predicate { $0.key == key })
            ?? {
                let created = SchemaCacheRecord(key: key)
                modelContext.insert(created)
                return created
            }()
        record.fetchedAt = fetchedAt
        record.schemaJSON = try encode(schema, what: "GraphQL schema")
        try save()
    }

    // MARK: Drafts (F01.10)

    public func saveDraft(_ request: RequestItem, key: String, requestID: UUID?, now: Date = Date()) throws(DataError) {
        let record =
            try first(DraftRecord.self, #Predicate { $0.key == key })
            ?? {
                let created = DraftRecord(key: key)
                modelContext.insert(created)
                return created
            }()
        record.requestKey = requestID?.uuidString
        record.updatedAt = now
        record.itemJSON = try encode(request, what: "draft")
        try save()
    }

    public func draft(key: String) throws(DataError) -> RequestItem? {
        try first(DraftRecord.self, #Predicate { $0.key == key })?.itemJSON.flatMap {
            try? decoder.decode(RequestItem.self, from: $0)
        }
    }

    public func drafts() throws(DataError) -> [(key: String, request: RequestItem)] {
        try fetch(FetchDescriptor<DraftRecord>(sortBy: [SortDescriptor(\.updatedAt)])).compactMap { record in
            guard let item = record.itemJSON.flatMap({ try? decoder.decode(RequestItem.self, from: $0) }) else {
                return nil
            }
            return (record.key, item)
        }
    }

    public func deleteDraft(key: String) throws(DataError) {
        try deleteAll(DraftRecord.self, #Predicate { $0.key == key })
        try save()
    }

    // MARK: Erase (X04.2)

    public func eraseEverything() throws(DataError) {
        try deleteAll(CollectionRecord.self, nil)
        try deleteAll(FolderRecord.self, nil)
        try deleteAll(RequestRecord.self, nil)
        try deleteAll(EnvironmentRecord.self, nil)
        try deleteAll(HistoryRecord.self, nil)
        try deleteAll(CookieRecord.self, nil)
        try deleteAll(SchemaCacheRecord.self, nil)
        try deleteAll(DraftRecord.self, nil)
        try save()
    }

    /// Row counts per model, for tests and diagnostics.
    public func rowCounts() throws(DataError) -> [String: Int] {
        [
            "collections": try count(CollectionRecord.self, nil), "folders": try count(FolderRecord.self, nil),
            "requests": try count(RequestRecord.self, nil), "environments": try count(EnvironmentRecord.self, nil),
            "history": try count(HistoryRecord.self, nil), "cookies": try count(CookieRecord.self, nil),
            "schemas": try count(SchemaCacheRecord.self, nil), "drafts": try count(DraftRecord.self, nil),
        ]
    }

    // MARK: Helpers

    private func collectionRecord(_ id: UUID) throws(DataError) -> CollectionRecord {
        let key = id.uuidString
        guard let record = try first(CollectionRecord.self, #Predicate { $0.key == key }) else {
            throw .notFound(what: "collection")
        }
        return record
    }

    private func summary(from record: CollectionRecord) -> CollectionSummary? {
        guard let id = UUID(uuidString: record.key) else { return nil }
        return CollectionSummary(
            id: id, name: record.name, storage: CollectionStorage(rawValue: record.kind) ?? .native,
            bookmark: record.bookmark,
            sortOrder: record.sortOrder, useCookieJar: record.useCookieJar, createdAt: record.createdAt)
    }

    /// Builds folder values with `/`-separated paths from the parent chain (cycles are cut).
    private func folders(from records: [FolderRecord]) -> [StoredFolder] {
        let byKey = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return records.compactMap { record in
            guard let id = UUID(uuidString: record.key) else { return nil }
            var components = [record.name]
            var visited: Set<String> = [record.key]
            var parent = record.parentKey
            while let key = parent, let next = byKey[key], visited.insert(key).inserted {
                components.insert(next.name, at: 0)
                parent = next.parentKey
            }
            let settings =
                record.settingsJSON.flatMap { try? decoder.decode(FolderSettings.self, from: $0) } ?? FolderSettings()
            return StoredFolder(
                folder: RequestFolder(
                    id: id, name: record.name, path: components.joined(separator: "/"), settings: settings),
                parentID: record.parentKey.flatMap(UUID.init(uuidString:)), sortOrder: record.sortOrder)
        }
    }

    private func nextCollectionOrder(excluding key: String) throws(DataError) -> Int {
        let existing = try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.key != key }))
        return (existing.map(\.sortOrder).max() ?? -1) + 1
    }

    private func encode<T: Encodable>(_ value: T, what: String) throws(DataError) -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw .encodingFailed(what: what)
        }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws(DataError) -> [T] {
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: String(describing: error))
        }
    }

    private func first<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>) throws(DataError) -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func count<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>?) throws(DataError) -> Int {
        do {
            return try modelContext.fetchCount(FetchDescriptor<T>(predicate: predicate))
        } catch {
            throw .storeUnavailable(underlying: String(describing: error))
        }
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>?) throws(DataError) {
        for record in try fetch(FetchDescriptor<T>(predicate: predicate)) { modelContext.delete(record) }
    }

    private func save() throws(DataError) {
        do {
            try modelContext.save()
        } catch {
            throw .saveFailed(underlying: String(describing: error))
        }
    }
}
