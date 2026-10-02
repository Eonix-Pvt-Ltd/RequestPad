import Foundation
import RPCore
import RPData
import RPServices
import RPStore
import Testing

@testable import RequestPad

/// Builds an isolated app: in-memory store and secrets, throwaway defaults, scripted HTTP.
@MainActor
enum TestApp {
    static func make(
        isPro: Bool = false, client: FakeHTTPClient = FakeHTTPClient(json: #"{"token":"abc","items":[1,2]}"#)
    ) throws -> AppModel {
        try make(isPro: isPro, client: client, transport: FakeTransport([]))
    }

    /// The real URLSession client and transport, for end-to-end tests against Local Echo.
    static func makeLive(isPro: Bool = false) throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try make(
            isPro: isPro,
            client: URLSessionHTTPClient(
                configuration: HTTPClientConfiguration(temporaryDirectory: root.appending(path: "Bodies"))),
            transport: URLSessionTransport(), root: root)
    }

    static func make(
        isPro: Bool, client: any HTTPClient, transport: any HTTPTransport,
        root: URL = FileManager.default.temporaryDirectory.appending(
            path: "app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    ) throws -> AppModel {
        let locations = StorageLocations(
            applicationSupport: root.appending(path: "Support", directoryHint: .isDirectory),
            temporary: root.appending(path: "Temp", directoryHint: .isDirectory))
        try locations.prepare()
        let defaults = try #require(UserDefaults(suiteName: "RequestPadTests-\(UUID().uuidString)"))
        let environment = AppEnvironment(
            locations: locations, store: LocalStore(modelContainer: try PersistenceContainer.makeInMemory()),
            secrets: InMemorySecretStore(),
            preferences: Preferences(defaults: defaults), folderAccess: PathBookmarks(),
            authenticator: FakeAuthenticator(),
            httpClient: client, transport: transport, isUITesting: true,
            storeClient: FakeStoreClient(
                entitlements: isPro
                    ? [TransactionSnapshot(id: 1, productID: ProductID.lifetime.rawValue, purchaseDate: Date())] : []))
        let store = EntitlementManager(client: environment.storeClient, state: EntitlementState(isPro: isPro))
        return AppModel(environment: environment, store: store)
    }

    /// Waits for the editor's send task to finish.
    static func waitForSend(_ editor: RequestEditorModel) async {
        for _ in 0..<500 where editor.isSending {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
@Suite("LaunchModel")
struct LaunchModelTests {
    @Test func successfulPreparationIsReady() throws {
        let app = try TestApp.make()
        let model = LaunchModel { app.environment }
        #expect(model.appModel != nil)
    }

    @Test func failedPreparationIsRecoverableByRetry() throws {
        let app = try TestApp.make()
        let model = LaunchModel { () throws(DataError) -> AppEnvironment in
            throw .storeUnavailable(underlying: "disk full")
        }
        guard case .failed(let error) = model.state else {
            Issue.record("Expected a failure")
            return
        }
        #expect(!error.title.isEmpty)
        model.retry { app.environment }
        #expect(model.appModel != nil)
    }

    @Test func livePreparationSucceedsInTestHost() throws {
        let prepared = try LaunchModel.prepareLiveLocations()
        for directory in prepared.ownedDirectories {
            #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        }
    }
}

@MainActor
@Suite("AppModel")
struct AppModelTests {
    @Test func freeTierAllowsOneCollectionAndAsksForPro() async throws {
        let app = try TestApp.make()
        await app.load()
        #expect(await app.createCollection(named: "  First  ") != nil)
        #expect(app.userCollections.map(\.summary.name) == ["First"])
        #expect(await app.createCollection(named: "Second") == nil)
        #expect(app.requestedProFeature == .unlimitedCollections)
        #expect(await app.createCollection(named: "   ") == nil)
    }

    @Test func sampleDataDoesNotCountTowardsTheLimit() async throws {
        let app = try TestApp.make()
        await app.load()
        await app.loadSampleData()
        defer { Task { await app.stopEcho() } }
        #expect(app.collections.contains { $0.summary.storage == .sample })
        #expect(app.activeEnvironment(for: SampleData.collectionID) != nil)
        #expect(app.globals.variables.contains { $0.name == SampleData.echoVariable })
        #expect(await app.createCollection(named: "Mine") != nil)
    }

    @Test func requestsCanBeCreatedRenamedMovedAndDeleted() async throws {
        let app = try TestApp.make()
        await app.load()
        let collectionID = try #require(await app.createCollection(named: "API"))
        let folderKey = try #require(await app.createFolder(in: collectionID, parentKey: nil, name: "Users"))
        let first = try #require(await app.createRequest(in: collectionID, folderKey: nil))
        let second = try #require(await app.createRequest(in: collectionID, folderKey: nil))
        let renamed = try #require(await app.renameRequest(first, to: "List Users"))
        #expect(app.request(renamed)?.request.name == "List Users")
        let moved = try #require(await app.moveRequest(renamed, toFolder: folderKey, position: 0))
        #expect(app.request(moved)?.folderKey == folderKey)
        let copy = try #require(await app.duplicateRequest(moved))
        #expect(app.request(copy)?.request.name.contains("List Users") == true)
        await app.deleteRequest(second)
        #expect(app.request(second) == nil)
        #expect(app.runItems(collectionID: collectionID, folderKey: folderKey).count == 2)
    }

    @Test func collectionsReorder() async throws {
        let app = try TestApp.make(isPro: true)
        await app.load()
        let a = try #require(await app.createCollection(named: "A"))
        let b = try #require(await app.createCollection(named: "B"))
        let c = try #require(await app.createCollection(named: "C"))
        await app.moveCollections(from: IndexSet(integer: 2), to: 0)
        #expect(app.collections.map(\.id) == [c, a, b])
        await app.moveCollections(from: IndexSet(integer: 0), to: 3)
        #expect(app.collections.map(\.id) == [a, b, c])
    }

    /// App Review crash on 1.0.0 (3), macOS: dragging a request row inside an expanded collection made `onMove` report
    /// indices beyond the collection list, and `moveCollections` trapped on an out-of-range index.
    @Test func collectionsReorderIgnoresOutOfRangeIndices() async throws {
        let app = try TestApp.make(isPro: true)
        await app.load()
        let a = try #require(await app.createCollection(named: "A"))
        let b = try #require(await app.createCollection(named: "B"))
        await app.moveCollections(from: IndexSet(integer: 7), to: 0)
        await app.moveCollections(from: IndexSet([0, 5]), to: 1)
        await app.moveCollections(from: IndexSet(integer: 0), to: 9)
        await app.moveCollections(from: IndexSet(integer: 0), to: -1)
        await app.moveCollections(from: IndexSet(), to: 0)
        #expect(app.collections.map(\.id) == [a, b])
    }

    @Test func secretVariablesLiveInTheSecretStoreAndCanBeRevealed() async throws {
        let app = try TestApp.make()
        await app.load()
        let collectionID = try #require(await app.createCollection(named: "API"))
        let environment = Environment(
            name: "Staging",
            variables: [
                .plain("host", "https://staging.example"),
                Variable(name: "token", value: .secret(SecretRef(account: "draft"))),
            ])
        let key = try #require(
            await app.saveEnvironment(environment, key: nil, in: collectionID, secretValues: ["token": "s3cr3t"]))
        let saved = try #require(app.environments(for: collectionID).first { $0.key == key }?.environment)
        guard case .secret(let reference) = saved.variables.first(where: { $0.name == "token" })?.value else {
            Issue.record("token should stay secret")
            return
        }
        #expect(reference != SecretRef(account: "draft"))
        #expect(await app.revealSecret(reference) == "s3cr3t")
        app.setActiveEnvironment(key, for: collectionID)
        #expect(app.activeEnvironment(for: collectionID)?.key == key)
        await app.deleteEnvironment(key: key, in: collectionID)
        #expect(app.activeEnvironment(for: collectionID) == nil)
        #expect(try await app.environment.secrets.secret(for: reference) == nil)
    }

    @Test func eraseAllDataResetsEverything() async throws {
        let app = try TestApp.make()
        await app.load()
        _ = await app.createCollection(named: "API")
        app.completeOnboarding()
        app.appearance = .dark
        await app.eraseAllData()
        #expect(app.collections.isEmpty)
        #expect(app.history.isEmpty)
        #expect(!app.onboardingCompleted)
        #expect(app.appearance == .system)
    }

    @Test func exportAndImportRoundTrip() async throws {
        let source = try TestApp.make()
        await source.load()
        let collectionID = try #require(await source.createCollection(named: "Exported"))
        _ = await source.createRequest(in: collectionID, folderKey: nil)
        let data = try #require(await source.exportAppData())
        let target = try TestApp.make()
        await target.load()
        await target.importAppData(data)
        #expect(target.collections.map(\.summary.name) == ["Exported"])
    }

    @Test func cookiesCanBeRemoved() async throws {
        let app = try TestApp.make(isPro: true)
        let jar = CookieJar(cookies: [
            Cookie(name: "a", value: "1", domain: "example.com", path: "/", createdAt: Date()),
            Cookie(name: "b", value: "2", domain: "other.test", path: "/", createdAt: Date()),
        ])
        try await app.environment.store.saveCookieJar(jar)
        #expect(await app.cookieJar().cookies.count == 2)
        let remaining = await app.removeCookies { $0.domain == "example.com" }
        #expect(remaining.cookies.map(\.name) == ["b"])
    }
}

@MainActor
@Suite("RequestEditorModel")
struct RequestEditorModelTests {
    private func makeEditor(isPro: Bool = false, client: FakeHTTPClient? = nil) async throws -> (
        AppModel, WorkspaceModel, RequestEditorModel
    ) {
        let app = try client.map { try TestApp.make(isPro: isPro, client: $0) } ?? TestApp.make(isPro: isPro)
        await app.load()
        let collectionID = try #require(await app.createCollection(named: "API"))
        let reference = try #require(await app.createRequest(in: collectionID, folderKey: nil))
        let workspace = WorkspaceModel(app: app)
        workspace.selection = .request(reference)
        return (app, workspace, try #require(workspace.editor))
    }

    @Test func urlAndQueryParametersStayInSync() async throws {
        let (_, _, editor) = try await makeEditor()
        editor.urlDidChange("https://api.example.com/items?page=2&q=a")
        #expect(editor.request.queryParams.map(\.name) == ["page", "q"])
        var rows = editor.request.queryParams
        rows[0].value = "3"
        editor.queryParamsDidChange(rows)
        #expect(editor.request.url == "https://api.example.com/items?page=3&q=a")
    }

    @Test func pastingCurlReplacesTheRequestButKeepsItsName() async throws {
        let (_, _, editor) = try await makeEditor()
        let name = editor.request.name
        editor.urlDidChange("curl -X POST https://api.example.com/users -H 'Accept: application/json' -d '{\"a\":1}'")
        #expect(editor.request.method == .post)
        #expect(editor.request.url == "https://api.example.com/users")
        #expect(editor.request.headers.contains { $0.name == "Accept" })
        #expect(editor.request.name == name)
    }

    @Test func saveClearsUnsavedChangesAndPersists() async throws {
        let (app, _, editor) = try await makeEditor()
        editor.request.url = "https://api.example.com/saved"
        #expect(editor.hasUnsavedChanges)
        await editor.save()
        #expect(!editor.hasUnsavedChanges)
        let reference = try #require(editor.reference)
        #expect(app.request(reference)?.request.url == "https://api.example.com/saved")
        editor.request.url = "https://changed"
        await editor.revert()
        #expect(editor.request.url == "https://api.example.com/saved")
    }

    @Test func draftsSurviveReopening() async throws {
        let (app, _, editor) = try await makeEditor()
        editor.request.url = "https://draft.example"
        try await Task.sleep(for: .milliseconds(800))
        let reference = try #require(editor.reference)
        let reopened = RequestEditorModel(
            app: app, reference: reference, request: try #require(app.request(reference)?.request),
            draftKey: editor.draftKey)
        for _ in 0..<100 where reopened.request.url != "https://draft.example" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reopened.request.url == "https://draft.example")
        #expect(reopened.hasUnsavedChanges)
    }

    @Test func sendRecordsHistoryAndAppliesTheDefaultTimeout() async throws {
        let client = FakeHTTPClient(json: #"{"ok":true}"#)
        let (app, _, editor) = try await makeEditor(client: client)
        app.preferences.defaultTimeoutSeconds = 45
        editor.request.url = "https://api.example.com/ping"
        editor.send()
        await TestApp.waitForSend(editor)
        #expect(editor.sendState == .finished)
        #expect(editor.result?.response.statusCode == 200)
        #expect(app.history.count == 1)
        let sent = try #require(await client.requests.first)
        #expect(sent.settings.timeoutMilliseconds == 45_000)
    }

    @Test func freeTierDoesNotRunAssertionsButProDoes() async throws {
        for isPro in [false, true] {
            let (_, _, editor) = try await makeEditor(isPro: isPro)
            editor.request.url = "https://api.example.com/items"
            editor.request.assertions = [Assertion(source: .status, operation: .equals, operand: "200")]
            editor.request.extractors = [Extractor(variableName: "token", source: .body(path: "$.token"))]
            editor.send()
            await TestApp.waitForSend(editor)
            #expect(editor.result?.assertions.count == (isPro ? 1 : 0))
            #expect(editor.result?.extractions.count == (isPro ? 1 : 0))
        }
    }

    @Test func graphQLAndOAuthAskForProOnTheFreeTier() async throws {
        let (app, _, editor) = try await makeEditor()
        editor.request.body = .graphQL(GraphQLBody(query: "{ a }"))
        editor.request.url = "https://api.example.com/graphql"
        editor.send()
        #expect(app.requestedProFeature == .graphQL)
        #expect(!editor.isSending)
        app.requestedProFeature = nil
        editor.request.body = .none
        editor.request.auth = .oauth2(OAuth2Config(grantType: .clientCredentials))
        await editor.save()
        #expect(app.requestedProFeature == .oauth2)
    }

    @Test func networkFailuresBecomeAPresentableError() async throws {
        let client = FakeHTTPClient { _ in .failure(.cannotFindHost("nowhere.invalid")) }
        let (_, _, editor) = try await makeEditor(client: client)
        editor.request.url = "https://nowhere.invalid"
        editor.send()
        await TestApp.waitForSend(editor)
        guard case .failed(let error) = editor.sendState else {
            Issue.record("Expected a failure, got \(editor.sendState)")
            return
        }
        #expect(!error.title.isEmpty)
    }

    @Test func runnerRunsItemsInOrder() async throws {
        let (app, _, editor) = try await makeEditor(isPro: true)
        let reference = try #require(editor.reference)
        editor.request.url = "https://api.example.com/one"
        editor.request.assertions = [Assertion(source: .status, operation: .equals, operand: "200")]
        await editor.save()
        _ = await app.createRequest(
            in: reference.collectionID, folderKey: nil,
            request: RequestItem(name: "Two", url: "https://api.example.com/two"))
        let items = app.runItems(collectionID: reference.collectionID, folderKey: nil)
        #expect(items.count == 2)
        var report: RunReport?
        for await event in app.run(items, collectionID: reference.collectionID, stopOnFailure: false) {
            if case .completed(let finished) = event { report = finished }
        }
        #expect(report?.passedCount == 2)
        #expect(app.history.isEmpty)
    }
}
