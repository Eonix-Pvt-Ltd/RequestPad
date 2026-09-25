import Foundation
import RPCore
import Testing

@testable import RPData

@Suite("FolderCollectionRepository")
struct FolderCollectionRepositoryTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "bru-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ text: String, _ path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    func makeSampleCollection() throws {
        try write(
            #"{"version":"1","name":"Shop","type":"collection","ignore":["node_modules",".git","drafts"]}"#,
            "bruno.json")
        try write(
            "headers {\n  X-App: shop\n}\n\nauth {\n  mode: bearer\n}\n\nauth:bearer {\n  token: {{token}}\n}\n",
            "collection.bru")
        try write(
            "meta {\n  name: List products\n  type: http\n  seq: 2\n}\n\nget {\n  url: {{baseUrl}}/products\n  body: none\n  auth: inherit\n}\n",
            "products/List products.bru")
        try write(
            "meta {\n  name: Create product\n  type: http\n  seq: 1\n}\n\npost {\n  url: {{baseUrl}}/products\n  body: json\n  auth: inherit\n}\n\nbody:json {\n  {\"name\":\"x\"}\n}\n\nscript:pre-request {\n  bru.setVar('a', 1)\n}\n",
            "products/Create product.bru")
        try write("meta {\n  name: Products\n  seq: 1\n}\n\nheaders {\n  X-Area: products\n}\n", "products/folder.bru")
        try write(
            "meta {\n  name: Health\n  type: http\n  seq: 1\n}\n\nget {\n  url: {{baseUrl}}/health\n}\n", "Health.bru")
        try write(
            "vars {\n  baseUrl: https://shop.example.com\n}\n\nvars:secret [\n  token\n]\n",
            "environments/Production.bru")
        try write("this is { not bru", "products/Broken.bru")
        try write("meta {\n  name: Ignored\n}\n\nget {\n  url: x\n}\n", "drafts/Ignored.bru")
        try write("{}", "node_modules/pkg/index.bru")
        try write("not a request", "README.md")
    }

    @Test func loadsCollectionFoldersRequestsEnvironmentsAndIssues() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSampleCollection()
        let repository = FolderCollectionRepository(root: root, collectionKey: "c1")
        let snapshot = try await repository.load()
        #expect(snapshot.name == "Shop")
        #expect(snapshot.settings.auth == .bearer(token: "{{token}}"))
        #expect(snapshot.folders.map(\.path) == ["products"])
        #expect(snapshot.folders[0].name == "Products")
        #expect(snapshot.folders[0].settings.headers == [KeyValue(name: "X-Area", value: "products")])
        #expect(
            snapshot.requests.map(\.path) == [
                "Health.bru", "products/Create product.bru", "products/List products.bru",
            ])
        #expect(snapshot.requests[1].request.hasUnsupportedScripts)
        #expect(snapshot.requests[1].folderPath == "products")
        #expect(snapshot.environments.map(\.fileName) == ["Production.bru"])
        let token = try #require(snapshot.environments[0].environment.variables.first { $0.name == "token" })
        #expect(token.value == .secret(SecretRef(account: "env:c1/environments/Production.bru:token")))
        #expect(snapshot.issues.map(\.path) == ["products/Broken.bru"])
        #expect(!(await repository.hasExternalChanges()))
    }

    @Test func savingPreservesUnknownBlocksAndDetectsConflicts() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSampleCollection()
        let repository = FolderCollectionRepository(root: root, collectionKey: "c1")
        let snapshot = try await repository.load()
        let original = try read("products/Create product.bru")
        var create = try #require(snapshot.requests.first { $0.request.name == "Create product" })
        create.request.url = "{{baseUrl}}/v2/products"
        try await repository.saveRequest(create.request, at: create.path, inFolder: "products")
        let saved = try read("products/Create product.bru")
        #expect(saved == original.replacingOccurrences(of: "{{baseUrl}}/products", with: "{{baseUrl}}/v2/products"))
        #expect(saved.contains("script:pre-request {"))

        // Someone else edits the file (e.g. git pull): the next save must not clobber it.
        try write(saved.replacingOccurrences(of: "v2", with: "v3"), "products/Create product.bru")
        #expect(await repository.hasExternalChanges())
        #expect(await repository.changedPaths() == ["products/Create product.bru"])
        create.request.name = "Create product (mine)"
        await #expect(throws: DataError.fileConflict(name: "Create product.bru")) {
            try await repository.saveRequest(create.request, at: create.path, inFolder: "products")
        }
        try await repository.saveRequest(create.request, at: create.path, inFolder: "products", overwrite: true)
        #expect(try read("products/Create product.bru").contains("name: Create product (mine)"))
        #expect(!(await repository.hasExternalChanges()))
    }

    @Test func newRequestsRenamesMovesAndDeletes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSampleCollection()
        let repository = FolderCollectionRepository(root: root, collectionKey: "c1")
        _ = try await repository.load()
        let first = try await repository.saveRequest(
            RequestItem(name: "Get: product/1?", url: "https://h"), at: nil, inFolder: "products")
        #expect(first == "products/Get- product-1-.bru")
        let second = try await repository.saveRequest(
            RequestItem(name: "Get: product/1?", url: "https://h"), at: nil, inFolder: "products")
        #expect(second == "products/Get- product-1- 2.bru")
        let (decoded, _) = try BruRequestCodec.decode(try read(second))
        #expect(decoded.name == "Get: product/1?")

        let renamed = try await repository.renameRequest(decoded, at: second, to: "Fetch one")
        #expect(renamed == "products/Fetch one.bru")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: second).path(percentEncoded: false)))
        #expect(try BruRequestCodec.decode(try read(renamed)).request.name == "Fetch one")
        let moved = try await repository.moveRequest(at: renamed, toFolder: nil)
        #expect(moved == "Fetch one.bru")
        try await repository.deleteRequest(at: moved)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: moved).path(percentEncoded: false)))
        await #expect(throws: DataError.invalidName("   ")) {
            try await repository.renameRequest(decoded, at: first, to: "   ")
        }
    }

    @Test func foldersAndEnvironments() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSampleCollection()
        let repository = FolderCollectionRepository(root: root, collectionKey: "c1")
        _ = try await repository.load()
        let admin = try await repository.createFolder(named: "Admin: Users", in: "products")
        #expect(admin == "products/Admin- Users")
        #expect(try read("products/Admin- Users/folder.bru").contains("name: Admin: Users"))
        await #expect(throws: DataError.nameInUse("Admin- Users")) {
            try await repository.createFolder(named: "Admin: Users", in: "products")
        }
        try await repository.saveFolderSettings(
            FolderSettings(auth: .basic(username: "a", password: "{{pw}}")), name: "Admin: Users", at: admin)
        let renamed = try await repository.renameFolder(at: admin, to: "Staff")
        #expect(renamed == "products/Staff")
        let reloaded = try await repository.load()
        let staff = try #require(reloaded.folders.first { $0.path == "products/Staff" })
        #expect(staff.name == "Staff")
        #expect(staff.settings.auth == .basic(username: "a", password: "{{pw}}"))
        try await repository.deleteFolder(at: renamed)
        #expect(try await repository.load().folders.map(\.path) == ["products"])
        await #expect(throws: DataError.invalidName("../x")) { try await repository.deleteFolder(at: "../x") }

        let environment = Environment(
            name: "Local",
            variables: [
                .plain("baseUrl", "http://localhost:3000"),
                Variable(name: "token", value: .secret(SecretRef(account: "ignored"))),
            ])
        let fileName = try await repository.saveEnvironment(environment, fileName: nil)
        #expect(fileName == "Local.bru")
        let text = try read("environments/Local.bru")
        #expect(text.contains("vars:secret [\n  token\n]"))
        #expect(!text.contains("ignored"))
        await #expect(throws: DataError.nameInUse("Local")) {
            try await repository.saveEnvironment(environment, fileName: nil)
        }
        try await repository.saveCollectionSettings(
            FolderSettings(headers: [KeyValue(name: "X-App", value: "shop2")], auth: .bearer(token: "{{token}}")))
        #expect(try read("collection.bru").contains("X-App: shop2"))
        try await repository.deleteEnvironment(fileName: fileName)
        #expect(try await repository.load().environments.map(\.fileName) == ["Production.bru"])
    }

    @Test func createsCollectionsOnlyInEmptyFolders() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", ".DS_Store")
        try FolderCollectionRepository.createCollection(named: " New API ", in: root)
        let snapshot = try await FolderCollectionRepository(root: root, collectionKey: "n").load()
        #expect(snapshot.name == "New API")
        #expect(snapshot.requests.isEmpty)
        #expect(throws: DataError.nameInUse("bruno.json")) {
            try FolderCollectionRepository.createCollection(named: "Again", in: root)
        }
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appending(path: "file.txt"))
        #expect(throws: DataError.folderNotEmpty) {
            try FolderCollectionRepository.createCollection(named: "X", in: other)
        }
        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: DataError.invalidName("  ")) {
            try FolderCollectionRepository.createCollection(named: "  ", in: empty)
        }
    }

    @Test func rejectsNonCollectionsAndLimits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: DataError.notABrunoCollection) {
            try await FolderCollectionRepository(root: root, collectionKey: "x").load()
        }
        try write("{\"name\":\"\"}", "bruno.json")
        await #expect(throws: DataError.self) {
            try await FolderCollectionRepository(root: root, collectionKey: "x").load()
        }
        try write(#"{"name":"Deep"}"#, "bruno.json")
        var path = ""
        for level in 0...(FolderCollectionRepository.maximumDepth + 1) { path += "d\(level)/" }
        try write("meta {\n  name: deep\n}\n\nget {\n  url: x\n}\n", path + "deep.bru")
        let snapshot = try await FolderCollectionRepository(root: root, collectionKey: "x").load()
        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.issues.contains { $0.message.contains("nested") })
    }

    @Test func symbolicLinksAreNotFollowed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"name":"Links"}"#, "bruno.json")
        let outside = FileManager.default.temporaryDirectory.appending(
            path: "outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("meta {\n  name: Outside\n}\n\nget {\n  url: x\n}\n".utf8).write(
            to: outside.appending(path: "Outside.bru"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "loop"), withDestinationURL: root)
        let snapshot = try await FolderCollectionRepository(root: root, collectionKey: "l").load()
        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.folders.isEmpty)
    }

    @Test(arguments: [
        ("Plain", "Plain"), ("a/b\\c:d*e?f\"g<h>i|j", "a-b-c-d-e-f-g-h-i-j"), ("...hidden", "hidden"),
        ("  spaced  ", "spaced"), (String(repeating: "x", count: 150), String(repeating: "x", count: 100)),
        ("line\nbreak", "line-break"),
    ])
    func sanitizesNames(input: String, expected: String) throws {
        #expect(try FolderCollectionRepository.sanitizedComponent(input) == expected)
    }

    @Test(arguments: ["", "   ", "...", "folder", "collection"])
    func rejectsReservedNames(input: String) {
        #expect(throws: DataError.self) { try FolderCollectionRepository.sanitizedComponent(input) }
    }
}

@Suite("NativeCollectionExporter")
struct NativeCollectionExporterTests {
    @Test func exportsNativeCollectionAsBrunoFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let summary = try await store.createCollection(
            name: "Shop API", storage: .native, settings: FolderSettings(auth: .bearer(token: "{{token}}")))
        let users = RequestFolder(name: "Users", path: "Users")
        let admin = RequestFolder(
            name: "Admin", path: "Users/Admin",
            settings: FolderSettings(headers: [KeyValue(name: "X-Admin", value: "1")]))
        try await store.upsertFolder(admin, parentID: users.id, in: summary.id, sortOrder: 2)
        try await store.upsertFolder(users, parentID: nil, in: summary.id, sortOrder: 1)
        try await store.upsertRequest(
            RequestItem(name: "Health", url: "{{base}}/health"), folderID: nil, in: summary.id)
        try await store.upsertRequest(
            RequestItem(name: "Promote", method: .post, url: "{{base}}/admin/promote", body: .json("{}")),
            folderID: admin.id, in: summary.id)
        let environment = Environment(
            name: "Local",
            variables: [
                .plain("base", "http://localhost"),
                Variable(name: "token", value: .secret(SecretRef(account: "env:x:token"))),
            ])

        let native = try await store.nativeCollection(summary.id)
        let count = try await NativeCollectionExporter.export(
            native, environments: [environment], to: root, collectionKey: "k")
        #expect(count == 2)
        let snapshot = try await FolderCollectionRepository(root: root, collectionKey: "k").load()
        #expect(snapshot.name == "Shop API")
        #expect(snapshot.settings.auth == .bearer(token: "{{token}}"))
        #expect(snapshot.folders.map(\.path) == ["Users", "Users/Admin"])
        #expect(snapshot.folders[1].settings.headers == [KeyValue(name: "X-Admin", value: "1")])
        #expect(snapshot.requests.map(\.path) == ["Health.bru", "Users/Admin/Promote.bru"])
        #expect(snapshot.requests[1].request.body == .json("{}"))
        #expect(snapshot.environments.first?.environment.variables.map(\.name) == ["base", "token"])
        #expect(snapshot.issues.isEmpty)
        let environmentText = try String(contentsOf: root.appending(path: "environments/Local.bru"), encoding: .utf8)
        #expect(!environmentText.contains("env:x:token"))
        await #expect(throws: DataError.nameInUse("bruno.json")) {
            try await NativeCollectionExporter.export(native, environments: [], to: root, collectionKey: "k")
        }
    }
}
