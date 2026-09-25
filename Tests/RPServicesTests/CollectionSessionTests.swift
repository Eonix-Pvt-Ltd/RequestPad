import Foundation
import RPCore
import RPData
import Testing

@testable import RPServices

@Suite("CollectionSession", .serialized)
struct CollectionSessionTests {
    /// Exercises the shared behavior of both session kinds.
    func exercise(_ session: any CollectionSession) async throws {
        let folder = try await session.createFolder(named: "Users", parentKey: nil)
        let sub = try await session.createFolder(named: "Admin", parentKey: folder)
        let key = try await session.saveRequest(
            RequestItem(name: "List", url: "https://h/users"), key: nil, folderKey: folder, overwrite: false)
        let adminKey = try await session.saveRequest(
            RequestItem(name: "Promote", method: .post, url: "https://h/admin"), key: nil, folderKey: sub,
            overwrite: false)
        let rootKey = try await session.saveRequest(
            RequestItem(name: "Health", url: "https://h/health"), key: nil, folderKey: nil, overwrite: false)
        try await session.saveFolderSettings(
            FolderSettings(headers: [KeyValue(name: "X-Area", value: "users")]), key: folder)
        try await session.saveCollectionSettings(FolderSettings(auth: .bearer(token: "{{t}}")))
        let envKey = try await session.saveEnvironment(
            Environment(name: "Dev", variables: [.plain("h", "x")]), key: nil)

        var tree = try await session.load()
        #expect(tree.settings.auth == .bearer(token: "{{t}}"))
        #expect(tree.children(of: nil).requests.map(\.request.name) == ["Health"])
        #expect(tree.children(of: nil).folders.map(\.name) == ["Users"])
        #expect(tree.children(of: folder).folders.map(\.name) == ["Admin"])
        #expect(tree.folderChain(to: sub).first?.headers == [KeyValue(name: "X-Area", value: "users")])
        #expect(tree.folderChain(to: sub).count == 2)
        #expect(tree.displayPath(of: adminKey) == "Users/Admin/Promote")
        #expect(tree.requestsInOrder(under: nil).map(\.request.name) == ["Health", "List", "Promote"])
        #expect(tree.requestsInOrder(under: folder).map(\.request.name) == ["List", "Promote"])
        #expect(tree.environments.map(\.environment.name) == ["Dev"])

        var edited = try #require(tree.requests.first { $0.key == key }).request
        edited.url = "https://h/v2/users"
        let savedKey = try await session.saveRequest(edited, key: key, folderKey: folder, overwrite: false)
        #expect(savedKey == key)
        let renamedKey = try await session.renameRequest(edited, key: key, to: "List users")
        let movedKey = try await session.moveRequest(key: renamedKey, toFolder: nil, position: 0)
        tree = try await session.load()
        let moved = try #require(tree.requests.first { $0.key == movedKey })
        #expect(moved.request.name == "List users")
        #expect(moved.request.url == "https://h/v2/users")
        #expect(moved.folderKey == nil)

        let renamedFolder = try await session.renameFolder(key: sub, to: "Staff")
        tree = try await session.load()
        #expect(tree.folders.contains { $0.key == renamedFolder && $0.name == "Staff" })
        try await session.deleteFolder(key: folder)
        try await session.deleteRequest(key: rootKey)
        try await session.deleteEnvironment(key: envKey)
        tree = try await session.load()
        #expect(tree.folders.isEmpty)
        #expect(tree.requests.map(\.request.name) == ["List users"])
        #expect(tree.environments.isEmpty)
        #expect(!session.secretKey(forEnvironment: "Dev.bru").isEmpty)
        await #expect(throws: DataError.self) { try await session.renameRequest(edited, key: movedKey, to: "  ") }
        await session.close()
    }

    @Test func nativeSession() async throws {
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let summary = try await store.createCollection(name: "Native", storage: .native)
        let session = NativeCollectionSession(id: summary.id, storage: .native, store: store)
        try await exercise(session)
        #expect(session.storage == .native)
        var iterator = session.externalChanges().makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func folderSessionAndExternalChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "session-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FolderCollectionRepository.createCollection(named: "Folder API", in: root)
        let access = PathBookmarks()
        let bookmark = try access.makeBookmark(for: root)
        let session = try await FolderCollectionSession(
            id: UUID(), bookmark: bookmark, folderAccess: access, refreshBookmark: { _ in })
        #expect(try await session.load().name == "Folder API")

        let changes = session.externalChanges()
        var iterator = changes.makeAsyncIterator()
        // RequestPad's own write doesn't count as an external change; an edit from outside does.
        _ = try await session.saveRequest(
            RequestItem(name: "Own", url: "https://h"), key: nil, folderKey: nil, overwrite: false)
        try Data("meta {\n  name: Outside\n}\n\nget {\n  url: https://h\n}\n".utf8).write(
            to: root.appending(path: "Outside.bru"))
        let event: Void? = await iterator.next()
        #expect(event != nil)
        #expect(try await session.load().requests.map(\.request.name).sorted() == ["Outside", "Own"])
        await session.close()

        let fresh = root.appending(path: "fresh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FolderCollectionRepository.createCollection(named: "Fresh", in: fresh)
        try await exercise(
            try await FolderCollectionSession(
                id: UUID(), bookmark: try access.makeBookmark(for: fresh), folderAccess: access,
                refreshBookmark: { _ in }))
    }

    @Test func staleBookmarksAreRefreshedAndMissingFoldersFail() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "stale-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try PathBookmarks().makeBookmark(for: root)
        let refreshed = RefreshRecorder()
        _ = try await FolderCollectionSession(
            id: UUID(), bookmark: bookmark, folderAccess: PathBookmarks(staleBookmarks: [bookmark]),
            refreshBookmark: { await refreshed.record($0) })
        #expect(await refreshed.count == 1)
        await #expect(throws: DataError.self) {
            _ = try await FolderCollectionSession(
                id: UUID(), bookmark: Data("/missing/folder".utf8), folderAccess: PathBookmarks(),
                refreshBookmark: { _ in })
        }
    }
}

actor RefreshRecorder {
    var count = 0
    func record(_ data: Data) { count += 1 }
}

@Suite("SampleData", .serialized)
struct SampleDataTests {
    @Test(.timeLimit(.minutes(1)))
    func installsIdempotentlyAndRunsAgainstLocalEcho() async throws {
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let server = LocalEchoServer()
        try await server.start()
        let base = try #require(await server.baseURL)
        defer { Task { await server.stop() } }
        try await store.upsertEnvironment(
            Environment(
                id: SampleData.globalsID, name: "Globals",
                variables: [.plain("keep", "1"), .plain("echoBaseURL", "old")]), for: nil)
        try await SampleData.install(into: store, echoBaseURL: base)
        try await SampleData.install(into: store, echoBaseURL: base)
        let counts = try await store.rowCounts()
        #expect(counts["collections"] == 1)
        #expect(counts["folders"] == 3)
        #expect(counts["requests"] == 14)
        let globals = try #require(try await store.environments(for: nil).first)
        #expect(globals.variables.map(\.name) == ["keep", "echoBaseURL"])

        let session = NativeCollectionSession(id: SampleData.collectionID, storage: .sample, store: store)
        let tree = try await session.load()
        #expect(tree.storage == .sample)
        let executor = RequestExecutor(
            client: URLSessionHTTPClient(), secrets: InMemorySecretStore(),
            oauth: OAuth2Service(
                transport: URLSessionTransport(), secrets: InMemorySecretStore(),
                authenticator: FakeWebAuthenticator { _ in .failure(.userCancelled) }),
            history: store, cookies: store)
        let context = SendContext(
            collection: tree.settings, environment: tree.environments.first?.environment, globals: globals,
            useCookieJar: true)
        var failures: [String] = []
        // Chained requests need the previous step's variables; the runner covers them below.
        let chainingKey = tree.folders.first { $0.name == "Chaining" }?.key
        for entry in tree.requests where !entry.request.name.contains("Slow") && entry.folderKey != chainingKey {
            var itemContext = context
            itemContext.folders = tree.folderChain(to: entry.folderKey)
            do {
                let result = try await executor.send(entry.request, context: itemContext)
                if result.assertions.contains(where: \.didFail) { failures.append(entry.request.name) }
            } catch {
                failures.append("\(entry.request.name): \(error.errorDescription ?? "")")
            }
        }
        #expect(failures.isEmpty, "\(failures)")

        let chain = tree.requestsInOrder(under: tree.folders.first { $0.name == "Chaining" }?.key)
        let runner = CollectionRunner(executor: executor)
        var report: RunReport?
        for await event in runner.run(chain.map { RunItem(request: $0.request) }, context: context, stopOnFailure: true)
        {
            if case .completed(let finished) = event { report = finished }
        }
        #expect(try #require(report).results.map(\.outcome) == [.passed, .passed])
    }
}
