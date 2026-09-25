import Foundation
import RPCore
import Testing

@testable import RPData

@Suite("AppDataTransfer")
struct AppDataTransferTests {
    @Test func exportImportRoundTripAndIdempotentMerge() async throws {
        let source = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let collection = try await source.createCollection(
            name: "API", storage: .native, settings: FolderSettings(auth: .bearer(token: "{{t}}")))
        let folder = RequestFolder(name: "Users", path: "Users")
        try await source.upsertFolder(folder, parentID: nil, in: collection.id, sortOrder: 3)
        try await source.upsertRequest(
            RequestItem(name: "List", url: "https://h/users"), folderID: folder.id, in: collection.id)
        try await source.upsertEnvironment(
            Environment(
                name: "Dev",
                variables: [
                    .plain("h", "x"), Variable(name: "secret", value: .secret(SecretRef(account: "env:1:secret"))),
                ]), for: collection.id)
        try await source.upsertEnvironment(Environment(name: "Globals", variables: [.plain("g", "1")]), for: nil)
        try await source.createCollection(name: "Linked folder", storage: .folder, bookmark: Data([9]))

        let data = try await AppDataTransfer(store: source).exportData(now: Date(timeIntervalSince1970: 0))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\" : \"lk.eonix.RequestPad.export\""))
        #expect(!text.contains("Linked folder"))

        let destination = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        #expect(try await AppDataTransfer(store: destination).importData(data) == 1)
        try await AppDataTransfer(store: destination).importData(data)
        #expect(
            try await destination.rowCounts() == [
                "collections": 1, "folders": 1, "requests": 1, "environments": 2, "history": 0, "cookies": 0,
                "schemas": 0, "drafts": 0,
            ])
        let imported = try await destination.nativeCollection(collection.id)
        #expect(imported.settings.auth == .bearer(token: "{{t}}"))
        #expect(imported.requests.first?.folderID == folder.id)
        #expect(imported.folders.first?.sortOrder == 3)
        let environment = try #require(try await destination.environments(for: collection.id).first)
        #expect(environment.variables[1].value == .secret(SecretRef(account: "env:1:secret")))
    }

    @Test func rejectsInvalidNewerAndOversizedExports() throws {
        #expect(throws: DataError.invalidExport(reason: "missing header")) {
            try AppDataTransfer.decode(Data("{}".utf8))
        }
        #expect(throws: DataError.invalidExport(reason: "missing header")) {
            try AppDataTransfer.decode(Data("not json".utf8))
        }
        #expect(throws: DataError.unsupportedExportVersion(2)) {
            try AppDataTransfer.decode(Data(#"{"format":"lk.eonix.RequestPad.export","version":2}"#.utf8))
        }
        #expect(throws: DataError.invalidExport(reason: "structure")) {
            try AppDataTransfer.decode(
                Data(#"{"format":"lk.eonix.RequestPad.export","version":1,"collections":5}"#.utf8))
        }
        #expect(throws: DataError.importTooLarge(limitBytes: AppDataExport.maximumBytes)) {
            try AppDataTransfer.decode(Data(count: AppDataExport.maximumBytes + 1))
        }
    }
}

@Suite("DataEraser")
struct DataEraserTests {
    @Test func erasesDatabaseSecretsPreferencesAndFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "erase-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StorageLocations(
            applicationSupport: root.appending(path: "support"), temporary: root.appending(path: "tmp"))
        try locations.prepare()
        try Data("payload".utf8).write(to: locations.diagnosticsDirectory.appending(path: "metric.json"))
        try Data("body".utf8).write(to: locations.responseBodiesDirectory.appending(path: "big.bin"))
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        try await store.createCollection(name: "C", storage: .native)
        let secrets = InMemorySecretStore(values: [SecretRef(account: "a"): "x"])
        let defaults = try #require(UserDefaults(suiteName: "erase-\(UUID().uuidString)"))
        let preferences = Preferences(defaults: defaults)
        preferences.onboardingCompleted = true
        defaults.set("other app key", forKey: "unrelated")

        try await DataEraser(store: store, secrets: secrets, preferences: preferences, locations: locations).eraseAll()
        #expect(try await store.rowCounts().values.allSatisfy { $0 == 0 })
        #expect(await secrets.count == 0)
        #expect(!preferences.onboardingCompleted)
        #expect(defaults.string(forKey: "unrelated") == "other app key")
        for directory in locations.ownedDirectories {
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
        }
    }
}

@Suite("Preferences")
struct PreferencesTests {
    @Test func defaultsClampingAndActiveEnvironments() throws {
        let defaults = try #require(UserDefaults(suiteName: "prefs-\(UUID().uuidString)"))
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.defaultTimeoutSeconds == 30)
        #expect(preferences.followRedirects)
        #expect(preferences.appearance == .system)
        preferences.defaultTimeoutSeconds = 9_999
        #expect(preferences.defaultTimeoutSeconds == 600)
        preferences.defaultTimeoutSeconds = -3
        #expect(preferences.defaultTimeoutSeconds == 1)
        preferences.followRedirects = false
        preferences.successfulRequestCount = -2
        #expect(preferences.successfulRequestCount == 0)
        preferences.successfulRequestCount = 5
        preferences.lastReviewPromptVersion = "1.0.0"
        preferences.localNetworkExplainerShown = true
        preferences.menuBarQuickSendEnabled = true
        preferences.localEchoEnabled = true
        preferences.appearance = .dark
        preferences.lastSelection = "c/r"
        preferences.onboardingCompleted = true
        let collection = UUID()
        let environment = UUID()
        preferences.setActiveEnvironment(environment, for: collection)
        #expect(preferences.activeEnvironment(for: collection) == environment)
        preferences.setActiveEnvironment(nil, for: collection)
        #expect(preferences.activeEnvironment(for: collection) == nil)
        #expect(!preferences.followRedirects)
        #expect(preferences.successfulRequestCount == 5)
        #expect(preferences.lastReviewPromptVersion == "1.0.0")
        #expect(
            preferences.localNetworkExplainerShown && preferences.menuBarQuickSendEnabled
                && preferences.localEchoEnabled)
        #expect(preferences.appearance == .dark)
        #expect(preferences.lastSelection == "c/r")
        preferences.removeAll()
        #expect(!preferences.onboardingCompleted)
        #expect(preferences.appearance == .system)
    }
}

@Suite("FolderAccess")
struct FolderAccessTests {
    @Test func pathBookmarksResolveAndReportStaleness() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "bm-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = PathBookmarks()
        let bookmark = try access.makeBookmark(for: directory)
        #expect(try access.resolve(bookmark).url.standardizedFileURL == directory.standardizedFileURL)
        #expect(try PathBookmarks(staleBookmarks: [bookmark]).resolve(bookmark).isStale)
        #expect(throws: DataError.bookmarkUnresolvable(reason: "missing")) {
            try access.resolve(Data("/no/such/dir".utf8))
        }
        let token = access.beginAccess(to: directory)
        #expect(!token.didStartScope)
        token.stop()
    }

    @Test func liveBookmarksForAccessibleFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = SecurityScopedBookmarks()
        let bookmark = try access.makeBookmark(for: directory)
        let resolved = try access.resolve(bookmark)
        #expect(
            resolved.url.standardizedFileURL.path(percentEncoded: false)
                == directory.standardizedFileURL.path(percentEncoded: false))
        let token = access.beginAccess(to: resolved.url)
        token.stop()
        token.stop()
        #expect(!token.didStartScope)
        #expect(throws: DataError.self) { try access.resolve(Data("garbage".utf8)) }
    }
}

@Suite("FolderWatcher")
struct FolderWatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func reportsChangesInNestedFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "watch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = FolderWatcher(root: root)
        let events = watcher.events()
        var iterator = events.makeAsyncIterator()
        try Data("a".utf8).write(to: root.appending(path: "sub/new.bru"))
        let first: Void? = await iterator.next()
        #expect(first != nil)
        try FileManager.default.createDirectory(
            at: root.appending(path: "sub/deeper"), withIntermediateDirectories: true)
        _ = await iterator.next()
        try Data("b".utf8).write(to: root.appending(path: "sub/deeper/file.bru"))
        let second: Void? = await iterator.next()
        #expect(second != nil)
        watcher.stop()
        #expect(await iterator.next() == nil)
    }
}
