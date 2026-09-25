import Foundation
import RPCore
import SwiftData
import Testing

@testable import RPData

@Suite("LocalStore")
struct LocalStoreTests {
    let store: LocalStore
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
    }

    @Test func collectionLifecycle() async throws {
        let first = try await store.createCollection(name: "API", storage: .native, now: now)
        let sample = try await store.createCollection(name: "Sample", storage: .sample, now: now.addingTimeInterval(1))
        #expect(try await store.collections().map(\.name) == ["API", "Sample"])
        #expect(first.sortOrder == 0)
        #expect(sample.sortOrder == 1)
        try await store.renameCollection(first.id, to: "Shop API")
        try await store.reorderCollections([sample.id, first.id])
        #expect(try await store.collections().map(\.name) == ["Sample", "Shop API"])
        try await store.setCookieJarEnabled(false, for: first.id)
        try await store.updateCollectionBookmark(first.id, bookmark: Data([1, 2]))
        let updated = try #require(try await store.collections().first { $0.id == first.id })
        #expect(!updated.useCookieJar)
        #expect(updated.bookmark == Data([1, 2]))
        let settings = FolderSettings(headers: [KeyValue(name: "X", value: "1")], auth: .bearer(token: "{{t}}"))
        try await store.updateCollectionSettings(first.id, settings: settings)
        #expect(try await store.nativeCollection(first.id).settings == settings)
        await #expect(throws: DataError.notFound(what: "collection")) {
            try await store.renameCollection(UUID(), to: "x")
        }
    }

    @Test func upsertsAreIdempotent() async throws {
        let collectionID = UUID()
        let folder = RequestFolder(name: "Users", path: "Users")
        let request = RequestItem(name: "List", url: "https://h/users")
        let environment = Environment(name: "Local", variables: [.plain("host", "localhost")])
        let entry = HistoryEntry(
            request: request, response: ResponseSummary(statusCode: 200, durationMilliseconds: 5, sizeBytes: 10),
            sentAt: now)
        var jar = CookieJar()
        jar.upsert(Cookie(name: "a", value: "1", domain: "h.com", createdAt: now), now: now)
        let schema = GraphQLSchema(
            queryType: "Query", mutationType: nil, subscriptionType: nil,
            types: [
                "Query": .init(
                    name: "Query", kind: .object, fields: [], inputFields: [], enumValues: [], possibleTypes: [],
                    description: nil)
            ])
        for _ in 0..<2 {
            try await store.createCollection(name: "C", storage: .native, id: collectionID, now: now)
            try await store.upsertFolder(folder, parentID: nil, in: collectionID)
            try await store.upsertRequest(request, folderID: folder.id, in: collectionID, now: now)
            try await store.upsertEnvironment(environment, for: collectionID)
            try await store.upsertEnvironment(
                Environment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(), name: "Globals"),
                for: nil)
            try await store.appendHistory(entry, limit: 100)
            try await store.saveCookieJar(jar)
            try await store.cacheSchema(schema, for: "https://h/graphql", fetchedAt: now)
            try await store.saveDraft(request, key: "tab-1", requestID: request.id, now: now)
        }
        #expect(
            try await store.rowCounts() == [
                "collections": 1, "folders": 1, "requests": 1, "environments": 2, "history": 1, "cookies": 1,
                "schemas": 1, "drafts": 1,
            ])
    }

    @Test func foldersRequestsAndMoves() async throws {
        let collection = try await store.createCollection(name: "C", storage: .native)
        let users = RequestFolder(name: "Users", path: "Users")
        let admin = RequestFolder(
            name: "Admin", path: "Users/Admin", settings: FolderSettings(auth: .basic(username: "a", password: "b")))
        try await store.upsertFolder(users, parentID: nil, in: collection.id, sortOrder: 0)
        try await store.upsertFolder(admin, parentID: users.id, in: collection.id, sortOrder: 1)
        let requests = (1...3).map { RequestItem(name: "R\($0)", url: "https://h/\($0)", sortOrder: $0) }
        for request in requests { try await store.upsertRequest(request, folderID: nil, in: collection.id) }
        let inAdmin = RequestItem(name: "Secret", url: "https://h/admin", sortOrder: 1)
        try await store.upsertRequest(inAdmin, folderID: admin.id, in: collection.id)

        let loaded = try await store.nativeCollection(collection.id)
        #expect(loaded.folders.map(\.folder.path) == ["Users", "Users/Admin"])
        #expect(loaded.folders[1].folder.settings.auth == .basic(username: "a", password: "b"))
        #expect(loaded.requests.map(\.request.name) == ["R1", "Secret", "R2", "R3"])
        #expect(try await store.requestCount(in: collection.id) == 4)

        try await store.moveRequest(requests[2].id, toFolder: nil, at: 0)
        let reordered = try await store.nativeCollection(collection.id).requests.filter { $0.folderID == nil }
        #expect(reordered.map(\.request.name) == ["R3", "R1", "R2"])
        #expect(reordered.map(\.request.sortOrder) == [1, 2, 3])
        try await store.moveRequest(requests[0].id, toFolder: admin.id, at: 99)
        #expect(try await store.request(requests[0].id).folderID == admin.id)

        try await store.deleteFolder(users.id)
        let afterDelete = try await store.nativeCollection(collection.id)
        #expect(afterDelete.folders.isEmpty)
        #expect(afterDelete.requests.map(\.request.name) == ["R3", "R2"])
        try await store.deleteRequest(requests[1].id)
        #expect(try await store.requestCount(in: collection.id) == 1)
        await #expect(throws: DataError.notFound(what: "request")) { try await store.request(UUID()) }
        await #expect(throws: DataError.notFound(what: "request")) {
            try await store.moveRequest(UUID(), toFolder: nil, at: 0)
        }
    }

    @Test func searchAndCascadingCollectionDelete() async throws {
        let collection = try await store.createCollection(name: "C", storage: .native)
        try await store.upsertRequest(
            RequestItem(name: "List users", method: .get, url: "https://api/users"), folderID: nil, in: collection.id)
        try await store.upsertRequest(
            RequestItem(name: "Create order", method: .post, url: "https://api/orders"), folderID: nil,
            in: collection.id)
        try await store.upsertEnvironment(Environment(name: "Dev"), for: collection.id)
        #expect(try await store.searchRequests("USERS").map(\.request.name) == ["List users"])
        #expect(try await store.searchRequests("post").map(\.request.name) == ["Create order"])
        #expect(try await store.searchRequests("orders").count == 1)
        #expect(try await store.searchRequests("  ").isEmpty)
        try await store.deleteCollection(collection.id)
        #expect(try await store.rowCounts()["requests"] == 0)
        #expect(try await store.environments(for: collection.id).isEmpty)
    }

    @Test func environmentsAndGlobals() async throws {
        let collection = try await store.createCollection(name: "C", storage: .native)
        let secret = Variable(name: "token", value: .secret(SecretRef(account: "env:x:token")))
        try await store.upsertEnvironment(
            Environment(name: "Staging", variables: [.plain("host", "s"), secret]), for: collection.id, sortOrder: 1)
        try await store.upsertEnvironment(Environment(name: "Local"), for: collection.id, sortOrder: 0)
        try await store.upsertEnvironment(Environment(name: "Globals", variables: [.plain("g", "1")]), for: nil)
        let environments = try await store.environments(for: collection.id)
        #expect(environments.map(\.name) == ["Local", "Staging"])
        #expect(environments[1].variables[1].value == .secret(SecretRef(account: "env:x:token")))
        #expect(try await store.environments(for: nil).map(\.name) == ["Globals"])
        try await store.deleteEnvironment(environments[0].id)
        #expect(try await store.environments(for: collection.id).count == 1)
    }

    @Test func historyIsNewestFirstPrunedAndSearchable() async throws {
        for index in 0..<5 {
            let request = RequestItem(name: index == 3 ? "Special" : "R\(index)", url: "https://h/\(index)")
            let entry = HistoryEntry(
                request: request, response: ResponseSummary(statusCode: 200, durationMilliseconds: 1, sizeBytes: 1),
                sentAt: now.addingTimeInterval(Double(index)))
            try await store.appendHistory(entry, limit: 3)
        }
        let history = try await store.history()
        #expect(history.map(\.request.name) == ["R4", "Special", "R2"])
        #expect(try await store.history(matching: "special").count == 1)
        #expect(try await store.history(limit: 1).count == 1)
        try await store.pruneHistory(to: 1)
        #expect(try await store.history().map(\.request.name) == ["R4"])
        try await store.deleteHistoryEntry(try #require(history.first).id)
        #expect(try await store.history().isEmpty)
        try await store.appendHistory(
            HistoryEntry(
                request: RequestItem(name: "x"),
                response: ResponseSummary(
                    statusCode: nil, durationMilliseconds: 0, sizeBytes: 0, errorSummary: "Timed out"), sentAt: now),
            limit: 10)
        try await store.clearHistory()
        #expect(try await store.history().isEmpty)
    }

    @Test func cookieJarRoundTripReplacesRemovedCookies() async throws {
        var jar = CookieJar()
        jar.upsert(Cookie(name: "a", value: "1", domain: "h.com", createdAt: now), now: now)
        jar.upsert(Cookie(name: "b", value: "2", domain: "h.com", createdAt: now), now: now)
        try await store.saveCookieJar(jar)
        #expect(try await store.cookieJar().cookies.count == 2)
        jar.remove(id: "h.com|/|a")
        jar.upsert(Cookie(name: "b", value: "updated", domain: "h.com", createdAt: now), now: now)
        try await store.saveCookieJar(jar)
        let loaded = try await store.cookieJar()
        #expect(loaded.cookies.map(\.value) == ["updated"])
    }

    @Test func schemaCacheAndDrafts() async throws {
        #expect(try await store.cachedSchema(for: "https://h/graphql") == nil)
        let schema = GraphQLSchema(queryType: "Q", mutationType: nil, subscriptionType: nil, types: [:])
        try await store.cacheSchema(schema, for: "https://h/graphql", fetchedAt: now)
        #expect(try await store.cachedSchema(for: "https://h/graphql")?.fetchedAt == now)
        let draft = RequestItem(name: "Unsaved", url: "https://h")
        try await store.saveDraft(draft, key: "tab", requestID: nil)
        #expect(try await store.draft(key: "tab") == draft)
        #expect(try await store.drafts().map(\.key) == ["tab"])
        try await store.deleteDraft(key: "tab")
        #expect(try await store.draft(key: "tab") == nil)
    }

    @Test func eraseEverythingEmptiesAllTables() async throws {
        let collection = try await store.createCollection(name: "C", storage: .native)
        try await store.upsertRequest(RequestItem(name: "r"), folderID: nil, in: collection.id)
        try await store.saveDraft(RequestItem(name: "d"), key: "k", requestID: nil)
        try await store.eraseEverything()
        #expect(try await store.rowCounts().values.allSatisfy { $0 == 0 })
    }

    @Test func persistentStoreOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "RequestPad.store")
        let id: UUID
        do {
            let store = LocalStore(modelContainer: try PersistenceContainer.make(at: url))
            id = try await store.createCollection(name: "Persisted", storage: .native).id
        }
        let reopened = LocalStore(modelContainer: try PersistenceContainer.make(at: url))
        #expect(try await reopened.collections().map(\.id) == [id])
    }

    @Test func errorsArePresentable() {
        let errors: [DataError] = [
            .storeUnavailable(underlying: "x"), .saveFailed(underlying: "x"), .encodingFailed(what: "x"),
            .notFound(what: "x"),
            .keychain(status: -1, operation: "read"), .keychainItemNotFound, .authenticationFailed(reason: "x"),
            .bookmarkStale,
            .bookmarkUnresolvable(reason: "x"), .accessDenied(path: "p"), .fileReadFailed(name: "n", reason: "r"),
            .fileWriteFailed(name: "n", reason: "r"), .fileConflict(name: "n"), .invalidName("n"), .nameInUse("n"),
            .folderNotEmpty,
            .notABrunoCollection, .tooManyFiles(limit: 1), .importTooLarge(limitBytes: 1), .unsupportedExportVersion(9),
            .invalidExport(reason: "r"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }
}
