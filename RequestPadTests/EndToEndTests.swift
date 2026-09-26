import Foundation
import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import RequestPad

/// An app with the real URLSession client and transport, talking to its own Local Echo over loopback.
@MainActor
struct EchoApp {
    let app: AppModel
    let base: String
    let collectionID: UUID

    init(isPro: Bool = true) async throws {
        app = try TestApp.makeLive(isPro: isPro)
        await app.load()
        await app.startEcho()
        base = try #require(await app.environment.echo.baseURL?.absoluteString)
        collectionID = try #require(await app.createCollection(named: "E2E"))
    }

    /// Saves `request` in the collection (optionally in a folder) and sends it with the collection context.
    func send(_ request: RequestItem, folderKey: String? = nil, environment: EnvironmentChoice = .active)
        async throws -> (SendResult, JSONValue?)
    {
        let reference = try #require(await app.createRequest(in: collectionID, folderKey: folderKey, request: request))
        let saved = try #require(app.request(reference)).request
        let result = try await app.send(saved, reference: reference, environment: environment)
        let echoed = result.response.body.inMemoryData.flatMap { try? JSONParser().parse($0) }
        return (result, echoed)
    }

    func stop() async { await app.stopEcho() }
}

private extension JSONValue {
    func at(_ path: String) -> JSONValue? { (try? JSONPath(path))?.firstValue(in: self) }
}

@MainActor
@Suite("End to end: requests and responses", .serialized)
struct EndToEndRequestTests {
    // AC: F01.1, F01.2
    @Test func customMethodAndOnlyEnabledQueryRowsAreSent() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        let editor = RequestEditorModel(
            app: echo.app, reference: nil, request: RequestItem(name: "Q", url: ""), draftKey: UUID().uuidString)
        editor.urlDidChange("\(echo.base)/echo?keep=1&drop=2")
        var rows = editor.request.queryParams
        rows[1].isEnabled = false
        editor.queryParamsDidChange(rows)
        var request = editor.request
        request.method = try #require(HTTPMethod(rawValue: "PURGE"))
        let (_, echoed) = try await echo.send(request)
        #expect(echoed?.at("$.method")?.stringValue == "PURGE")
        #expect(echoed?.at("$.query.keep[0]")?.stringValue == "1")
        #expect(echoed?.at("$.query.drop") == nil)
    }

    // AC: F01.3
    @Test func duplicateHeadersAreSeparateAndDisabledOnesAreDropped() async throws {
        let client = FakeHTTPClient(json: "{}")
        let app = try TestApp.make(client: client)
        var request = RequestItem(name: "H", url: "https://example.com")
        request.headers = [
            KeyValue(name: "X-Tag", value: "a"), KeyValue(name: "X-Tag", value: "b"),
            KeyValue(name: "X-Off", value: "no", isEnabled: false),
        ]
        _ = try await app.send(request, reference: nil)
        let sent = try #require(await client.requests.first)
        #expect(sent.headers.filter { $0.name == "X-Tag" }.map(\.value) == ["a", "b"])
        #expect(!sent.headers.contains { $0.name == "X-Off" })
    }

    // AC: F01.4
    @Test func jsonFormAndMultipartBodiesArriveIntact() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        var json = RequestItem(name: "J", method: .post, url: "\(echo.base)/echo")
        json.body = .json(#"{"name":"Ada","roles":["admin"]}"#)
        let (_, jsonEcho) = try await echo.send(json)
        #expect(jsonEcho?.at("$.body.json.name")?.stringValue == "Ada")
        #expect(jsonEcho?.at("$.headers.Content-Type")?.stringValue?.hasPrefix("application/json") == true)

        var form = RequestItem(name: "F", method: .post, url: "\(echo.base)/echo")
        form.body = .formURLEncoded([KeyValue(name: "a", value: "1"), KeyValue(name: "b", value: "two words")])
        let (_, formEcho) = try await echo.send(form)
        #expect(
            formEcho?.at("$.body.text")?.stringValue == "a=1&b=two+words"
                || formEcho?.at("$.body.text")?.stringValue == "a=1&b=two%20words")

        let file = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).txt")
        try Data("file contents".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reference = try BookmarkFileResolver.reference(
            for: file, baseDirectory: nil, folderAccess: echo.app.environment.folderAccess)
        var multipart = RequestItem(name: "M", method: .post, url: "\(echo.base)/echo")
        multipart.body = .multipart([
            MultipartField(name: "note", content: .text("hello")),
            MultipartField(name: "file", content: .files([reference])),
        ])
        let (_, multipartEcho) = try await echo.send(multipart)
        let text = try #require(multipartEcho?.at("$.body.text")?.stringValue)
        #expect(text.contains("hello"))
        #expect(text.contains("file contents"))
        #expect(text.contains(file.lastPathComponent))
        #expect(multipartEcho?.at("$.headers.Content-Type")?.stringValue?.hasPrefix("multipart/form-data") == true)
    }

    // AC: F01.7, F01.8
    @Test func connectionFailureHasASpecificMessageAndLoopbackHTTPWorks() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        let (ok, _) = try await echo.send(RequestItem(name: "L", url: "\(echo.base)/echo"))
        #expect(ok.response.statusCode == 200)
        do {
            _ = try await echo.app.send(RequestItem(name: "Refused", url: "http://127.0.0.1:1/"), reference: nil)
            Issue.record("Expected a connection failure")
        } catch {
            let presented = PresentedError(error)
            #expect(presented.title == ServiceError.cannotConnect("127.0.0.1").errorDescription)
            #expect(!presented.message.isEmpty)
        }
    }

    // AC: F02.1, F02.2, F02.3, F02.4
    @Test func statusTimingsHeadersAndJSONTree() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        let (result, _) = try await echo.send(RequestItem(name: "S", url: "\(echo.base)/status/404"))
        #expect(result.response.statusCode == 404)
        #expect(!result.response.reasonPhrase.isEmpty)
        let style = StatusBadgeStyle(statusClass: result.response.statusClass)
        #expect(style.systemImage == "exclamationmark.triangle")
        let timings = try #require(result.response.timings)
        #expect(timings.total > 0)
        #expect(result.response.headers.contains { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })
        let content = await ResponseContent.load(from: result.response)
        let json = try #require(content.json)
        #expect(try JSONPath("$.path").firstValue(in: json)?.stringValue == "/status/404")
        #expect(JSONNode(path: "$", label: "$", value: json).children?.isEmpty == false)
    }

    // AC: F02.5
    @Test func rawTextUsesTheDeclaredCharsetAndMarksInvalidBytes() async {
        let latin1 = FakeHTTPClient.response(
            for: ResolvedRequest(method: .get, url: URL(filePath: "/")), status: 200,
            body: Data([0x63, 0x61, 0x66, 0xE9]),
            headers: [(name: "Content-Type", value: "text/plain; charset=iso-8859-1")])
        let decoded = await ResponseContent.load(from: latin1)
        #expect(decoded.text == "café")
        #expect(decoded.encodingName == "iso-8859-1")
        let mostlyUTF8 = FakeHTTPClient.response(
            for: ResolvedRequest(method: .get, url: URL(filePath: "/")), status: 200,
            body: Data("hello world, this is text ".utf8) + Data([0xFF]),
            headers: [(name: "Content-Type", value: "text/plain")])
        let lossy = await ResponseContent.load(from: mostlyUTF8)
        #expect(lossy.isLossy)
        #expect(lossy.text.contains("\u{FFFD}"))
    }

    // AC: F02.6
    @Test func imagesPreview() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        let (result, _) = try await echo.send(RequestItem(name: "I", url: "\(echo.base)/image.png"))
        let content = await ResponseContent.load(from: result.response)
        #expect(content.kind == .image)
        #expect(PlatformImage(data: try #require(content.imageData)) != nil)
    }

    // AC: F02.7, F02.8
    @Test func largeBodiesAreSpooledShownInPartAndSavedWhole() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        let size = 12 * 1024 * 1024
        let (result, _) = try await echo.send(RequestItem(name: "Big", url: "\(echo.base)/bytes/\(size)"))
        guard case .file(_, let spooled) = result.response.body else {
            Issue.record("Expected the body on disk, got \(result.response.body)")
            return
        }
        #expect(spooled == size)
        let content = await ResponseContent.load(from: result.response)
        #expect(content.isTruncated)
        let wrapper = try ResponseBodyDocument(body: result.response.body).makeFileWrapper()
        let destination = FileManager.default.temporaryDirectory.appending(path: "saved-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        try wrapper.write(to: destination, originalContentsURL: nil)
        #expect(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize == size)
    }
}

@MainActor
@Suite("End to end: variables, auth and collections", .serialized)
struct EndToEndContextTests {
    // AC: F03.3, F05.2
    @Test func collectionAndFolderDefaultsAreInherited() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        await echo.app.saveCollectionSettings(
            FolderSettings(
                headers: [KeyValue(name: "X-Team", value: "core")], auth: .bearer(token: "collection-token")),
            for: echo.collectionID)
        let folderKey = try #require(await echo.app.createFolder(in: echo.collectionID, parentKey: nil, name: "Admin"))
        await echo.app.saveFolderSettings(
            FolderSettings(auth: .basic(username: "ada", password: "pw")), in: echo.collectionID, key: folderKey)
        let (_, root) = try await echo.send(RequestItem(name: "Root", url: "\(echo.base)/echo"))
        #expect(root?.at("$.headers.Authorization")?.stringValue == "Bearer collection-token")
        #expect(root?.at("$.headers.X-Team")?.stringValue == "core")
        let (_, nested) = try await echo.send(
            RequestItem(name: "Nested", url: "\(echo.base)/echo"), folderKey: folderKey)
        #expect(
            nested?.at("$.headers.Authorization")?.stringValue == "Basic " + Data("ada:pw".utf8).base64EncodedString())
        #expect(nested?.at("$.headers.X-Team")?.stringValue == "core")
    }

    // AC: F04.2, F04.3
    @Test func variablePrecedenceAndUnresolvedWarnings() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        var globals = echo.app.globals
        globals.variables += [.plain("who", "global"), .plain("only", "from-globals")]
        await echo.app.saveGlobals(globals, secretValues: [:])
        let key = try #require(
            await echo.app.saveEnvironment(
                Environment(name: "Dev", variables: [.plain("who", "environment")]), key: nil, in: echo.collectionID,
                secretValues: [:]))
        echo.app.setActiveEnvironment(key, for: echo.collectionID)
        var request = RequestItem(name: "V", url: "\(echo.base)/echo?who={{who}}&only={{only}}")
        request.headers = [KeyValue(name: "X-Who", value: "{{who}}")]
        let (_, fromEnvironment) = try await echo.send(request)
        #expect(fromEnvironment?.at("$.query.who[0]")?.stringValue == "environment")
        #expect(fromEnvironment?.at("$.query.only[0]")?.stringValue == "from-globals")
        request.variables = [KeyValue(name: "who", value: "request")]
        let (_, fromRequest) = try await echo.send(request)
        #expect(fromRequest?.at("$.headers.X-Who")?.stringValue == "request")

        let reference = try #require(
            await echo.app.createRequest(
                in: echo.collectionID, folderKey: nil,
                request: RequestItem(name: "U", url: "\(echo.base)/echo?x={{missing}}")))
        let editor = RequestEditorModel(
            app: echo.app, reference: reference, request: try #require(echo.app.request(reference)).request,
            draftKey: UUID().uuidString)
        #expect(editor.unresolvedVariables == ["missing"])
        // Sending is still allowed; the template is sent as typed.
        let (_, unresolved) = try await echo.send(RequestItem(name: "U2", url: "\(echo.base)/echo?x={{missing}}"))
        #expect(unresolved?.at("$.query.x[0]")?.stringValue == "{{missing}}")
    }

    // AC: F05.1
    @Test func bearerBasicAndAPIKeyAuth() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        var bearer = RequestItem(name: "B", url: "\(echo.base)/echo")
        bearer.auth = .bearer(token: "t0k")
        #expect(try await echo.send(bearer).1?.at("$.headers.Authorization")?.stringValue == "Bearer t0k")
        var basic = RequestItem(name: "Ba", url: "\(echo.base)/echo")
        basic.auth = .basic(username: "user", password: "p:ss")
        #expect(
            try await echo.send(basic).1?.at("$.headers.Authorization")?.stringValue
                == "Basic " + Data("user:p:ss".utf8).base64EncodedString())
        var headerKey = RequestItem(name: "K", url: "\(echo.base)/echo")
        headerKey.auth = .apiKey(APIKeyAuth(key: "X-API-Key", value: "k1"))
        #expect(try await echo.send(headerKey).1?.at("$.headers.X-API-Key")?.stringValue == "k1")
        var queryKey = RequestItem(name: "KQ", url: "\(echo.base)/echo")
        queryKey.auth = .apiKey(APIKeyAuth(key: "api_key", value: "k2", placement: .query))
        #expect(try await echo.send(queryKey).1?.at("$.query.api_key[0]")?.stringValue == "k2")
    }

    // AC: F05.3, F05.5
    @Test func oauthClientCredentialsFetchesAndSendsAToken() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        let key = try #require(
            await echo.app.saveEnvironment(
                Environment(
                    name: "Secrets", variables: [Variable(name: "secret", value: .secret(SecretRef(account: "new")))]),
                key: nil, in: echo.collectionID, secretValues: ["secret": "s3cr3t"]))
        echo.app.setActiveEnvironment(key, for: echo.collectionID)
        var request = RequestItem(name: "O", url: "\(echo.base)/echo")
        request.auth = .oauth2(
            OAuth2Config(
                grantType: .clientCredentials, accessTokenURL: "\(echo.base)/oauth/token", clientID: "client",
                clientSecret: "{{secret}}", scope: "read"))
        let (_, echoed) = try await echo.send(request)
        #expect(echoed?.at("$.headers.Authorization")?.stringValue?.hasPrefix("Bearer echo-") == true)

        var missingClient = request
        missingClient.auth = .oauth2(
            OAuth2Config(
                grantType: .clientCredentials, accessTokenURL: "\(echo.base)/oauth/token", clientID: "",
                credentialsPlacement: .body))
        do {
            _ = try await echo.send(missingClient)
            Issue.record("Expected invalid_client")
        } catch {
            let presented = PresentedError(error as? SendError ?? .unsupportedAuth(""))
            #expect("\(presented.title) \(presented.message)".localizedCaseInsensitiveContains("client"))
        }
    }

    // AC: F07.2
    @Test func curlExportResolvesVariablesAndMasksSecrets() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        let key = try #require(
            await echo.app.saveEnvironment(
                Environment(
                    name: "Env",
                    variables: [
                        .plain("host", "api.example.com"),
                        Variable(name: "token", value: .secret(SecretRef(account: "n"))),
                    ]),
                key: nil, in: echo.collectionID, secretValues: ["token": "super-secret"]))
        echo.app.setActiveEnvironment(key, for: echo.collectionID)
        var request = RequestItem(name: "C", url: "https://{{host}}/items")
        request.headers = [KeyValue(name: "Authorization", value: "Bearer {{token}}")]
        let reference = try #require(
            await echo.app.createRequest(in: echo.collectionID, folderKey: nil, request: request))
        let editor = RequestEditorModel(
            app: echo.app, reference: reference, request: try #require(echo.app.request(reference)).request,
            draftKey: UUID().uuidString)
        let resolved = try editor.previewResolved()
        let multiLine = CurlExporter.export(resolved)
        let singleLine = CurlExporter.export(resolved, style: .singleLine)
        for command in [multiLine, singleLine] {
            #expect(command.contains("https://api.example.com/items"))
            #expect(!command.contains("super-secret"))
            #expect(command.contains(Interpolator.maskedSecret))
        }
        #expect(multiLine.contains("\n"))
        #expect(!singleLine.contains("\n"))
    }

    // AC: P05.1
    @Test func extractedValuesFeedTheNextRequestAndPersist() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        let key = try #require(
            await echo.app.saveEnvironment(
                Environment(name: "Chain"), key: nil, in: echo.collectionID, secretValues: [:]))
        echo.app.setActiveEnvironment(key, for: echo.collectionID)
        var first = RequestItem(name: "First", url: "\(echo.base)/echo?id=42")
        var rule = Extractor(variableName: "itemID", source: .body(path: "$.query.id[0]"))
        rule.persistToEnvironment = true
        first.extractors = [rule, Extractor(variableName: "code", source: .status)]
        let (firstResult, _) = try await echo.send(first)
        #expect(firstResult.extractions.map(\.outcome) == [.extracted("42"), .extracted("200")])
        let (_, second) = try await echo.send(RequestItem(name: "Second", url: "\(echo.base)/items/{{itemID}}"))
        #expect(second?.at("$.path")?.stringValue == "/items/42")
        let environment = try #require(echo.app.environments(for: echo.collectionID).first { $0.key == key })
        #expect(environment.environment.variables.contains { $0.name == "itemID" && $0.value == .plain("42") })
    }

    // AC: P06.3
    @Test func runResultsExportAsJSON() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        var passing = RequestItem(name: "Ok", url: "\(echo.base)/status/200")
        passing.assertions = [Assertion(source: .status, operation: .equals, operand: "200")]
        var failing = RequestItem(name: "Missing", url: "\(echo.base)/status/404")
        failing.assertions = [Assertion(source: .status, operation: .equals, operand: "200")]
        _ = await echo.app.createRequest(in: echo.collectionID, folderKey: nil, request: passing)
        _ = await echo.app.createRequest(in: echo.collectionID, folderKey: nil, request: failing)
        var report: RunReport?
        for await event in echo.app.run(
            echo.app.runItems(collectionID: echo.collectionID, folderKey: nil), collectionID: echo.collectionID,
            stopOnFailure: false)
        {
            if case .completed(let finished) = event { report = finished }
        }
        let finished = try #require(report)
        #expect(finished.passedCount == 1)
        #expect(finished.failedCount == 1)
        let document = RunReportDocument(report: finished)
        let parsed = try JSONParser().parse(document.data)
        #expect(parsed.at("$.results")?.arrayValue?.count == 2)
    }

    // AC: P07.1, P07.2
    @Test func cookiesPersistOnlyWithPro() async throws {
        for isPro in [true, false] {
            let echo = try await EchoApp(isPro: isPro)
            _ = try await echo.send(RequestItem(name: "Set", url: "\(echo.base)/cookies/set?session=abc"))
            let (_, next) = try await echo.send(RequestItem(name: "Next", url: "\(echo.base)/echo"))
            let cookie = next?.at("$.headers.Cookie")?.stringValue
            #expect(isPro ? cookie == "session=abc" : cookie == nil, "isPro \(isPro): \(String(describing: cookie))")
            await echo.stop()
        }
    }

    // AC: P04.1, P04.2, P04.3
    @Test func graphQLSendsJSONPostAndFetchesACachedSchema() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        var request = RequestItem(name: "G", kind: .graphql, method: .post, url: "\(echo.base)/graphql")
        request.body = .graphQL(GraphQLBody(query: "{ echo { query } }", variables: #"{"a":1}"#))
        let (result, echoed) = try await echo.send(request)
        #expect(result.sentRequest.headerValue("Content-Type")?.hasPrefix("application/json") == true)
        #expect(result.sentRequest.method == .post)
        #expect(echoed?.at("$.data.echo.query")?.stringValue == "{ echo { query } }")
        #expect(echoed?.at("$.data.echo.variables.a")?.intValue == 1)

        let reference = try #require(
            await echo.app.createRequest(in: echo.collectionID, folderKey: nil, request: request))
        let editor = RequestEditorModel(
            app: echo.app, reference: reference, request: try #require(echo.app.request(reference)).request,
            draftKey: UUID().uuidString)
        await editor.fetchSchema()
        let schema = try #require(editor.schema, "schema error: \(editor.schemaError ?? "none")")
        let fresh = RequestEditorModel(
            app: echo.app, reference: reference, request: editor.request, draftKey: UUID().uuidString)
        await fresh.loadCachedSchema()
        #expect(fresh.schema == schema)
        let suggestions = GraphQLCompleter.completions(in: "{ ec", cursorOffset: 4, schema: schema)
        #expect(suggestions.contains { $0.label == "echo" })
    }
}

@MainActor
@Suite("End to end: folder collections and imports", .serialized)
struct EndToEndCollectionTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "folder-collection-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bruFiles(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "bru" }
    }

    // AC: P01.1, P01.2, P01.3, P01.5, P01.6
    @Test func newFolderCollectionIsBrunoAndEditsAreWrittenBack() async throws {
        let app = try TestApp.make(isPro: true)
        await app.load()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(await app.openFolderCollection(at: folder, createIfEmpty: "Git API"))
        #expect(
            FileManager.default.fileExists(atPath: folder.appending(path: "bruno.json").path(percentEncoded: false)))
        #expect(app.collection(id)?.summary.storage == .folder)

        let reference = try #require(
            await app.createRequest(
                in: id, folderKey: nil, request: RequestItem(name: "List Users", url: "https://api.example.com/users")))
        let requestFile = try #require(bruFiles(in: folder).first { $0.lastPathComponent == "List Users.bru" })
        #expect(try String(contentsOf: requestFile, encoding: .utf8).contains("https://api.example.com/users"))

        var edited = try #require(app.request(reference)).request
        edited.url = "https://api.example.com/v2/users"
        _ = try await app.saveRequest(edited, reference: reference)
        #expect(try String(contentsOf: requestFile, encoding: .utf8).contains("/v2/users"))

        _ = await app.saveEnvironment(
            Environment(name: "Prod", variables: [Variable(name: "token", value: .secret(SecretRef(account: "n")))]),
            key: nil,
            in: id, secretValues: ["token": "never-on-disk"])
        let environmentFile = try #require(bruFiles(in: folder).first { $0.lastPathComponent == "Prod.bru" })
        let environmentText = try String(contentsOf: environmentFile, encoding: .utf8)
        #expect(environmentText.contains("vars:secret"))
        #expect(environmentText.contains("token"))
        #expect(!environmentText.contains("never-on-disk"))

        // Reopening the same files as another collection reads the Bruno layout back (P01.1, P01.2).
        let reopened = try #require(await app.openFolderCollection(at: folder, createIfEmpty: nil))
        #expect(app.collection(reopened)?.tree?.requests.map(\.request.name) == ["List Users"])
    }

    // AC: P01.4
    @Test func externalChangesReloadAndConflictWithUnsavedEdits() async throws {
        let app = try TestApp.make(isPro: true)
        await app.load()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(await app.openFolderCollection(at: folder, createIfEmpty: "Sync"))
        let reference = try #require(
            await app.createRequest(
                in: id, folderKey: nil, request: RequestItem(name: "Item", url: "https://a.example")))
        let file = try #require(bruFiles(in: folder).first { $0.lastPathComponent == "Item.bru" })
        let editor = RequestEditorModel(
            app: app, reference: reference, request: try #require(app.request(reference)).request,
            draftKey: UUID().uuidString)
        editor.request.url = "https://local-edit.example"
        // Someone else (git pull, Bruno) changes the file.
        let external = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: "https://a.example", with: "https://from-git.example")
        try external.write(to: file, atomically: true, encoding: .utf8)
        await app.reloadTree(id)
        #expect(app.request(reference)?.request.url == "https://from-git.example")
        await editor.save()
        #expect(editor.conflict != nil)
        await editor.discardForFileVersion()
        #expect(editor.request.url == "https://from-git.example")
        #expect(editor.conflict == nil)

        // Without local edits, the editor follows the file (P01.4 reload).
        let external2 = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: "https://from-git.example", with: "https://second-pull.example")
        try external2.write(to: file, atomically: true, encoding: .utf8)
        await app.reloadTree(id)
        editor.adoptStoredVersion()
        #expect(editor.request.url == "https://second-pull.example")
        #expect(!editor.hasUnsavedChanges)
    }

    // AC: P01.7
    @Test func nativeCollectionConvertsToBruFiles() async throws {
        let app = try TestApp.make(isPro: true)
        await app.load()
        let id = try #require(await app.createCollection(named: "Native"))
        _ = await app.createRequest(
            in: id, folderKey: nil, request: RequestItem(name: "Ping", url: "https://ping.example"))
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await app.convertToFolder(id, destination: folder)
        #expect(app.presentedError == nil)
        #expect(
            FileManager.default.fileExists(atPath: folder.appending(path: "bruno.json").path(percentEncoded: false)))
        #expect(bruFiles(in: folder).contains { $0.lastPathComponent == "Ping.bru" })
    }

    // AC: P02.1, P02.2, P02.3
    @Test func openAPIImportsIntoFoldersPerTagAndFailsWholly() async throws {
        let app = try TestApp.make(isPro: true)
        await app.load()
        let yaml = """
            openapi: 3.1.0
            info: {title: Pets, version: "1"}
            servers: [{url: "https://pets.example"}]
            paths:
              /pets:
                get: {tags: [pets], summary: List pets}
                post:
                  tags: [pets]
                  summary: Add pet
                  requestBody:
                    content:
                      application/json:
                        schema: {$ref: "#/components/schemas/Pet"}
              /stores/{id}:
                get: {tags: [stores], summary: Get store}
            components:
              schemas:
                Pet: {type: object, properties: {name: {type: string}}}
            """
        let imported = try OpenAPIImporter.importDocument(Data(yaml.utf8))
        let id = try #require(await app.importCollection(imported))
        let tree = try #require(app.collection(id)?.tree)
        #expect(Set(tree.folders.map(\.name)) == ["pets", "stores"])
        #expect(tree.requests.count == 3)
        #expect(tree.requests.contains { $0.request.url.contains(":id") }, "\(tree.requests.map(\.request.url))")

        let before = app.collections.count
        #expect(throws: CoreError.self) {
            _ = try OpenAPIImporter.importDocument(Data("openapi: 3.0.0\npaths: [unclosed".utf8))
        }
        #expect(app.collections.count == before)
    }

    // AC: P03.1
    @Test func postmanImportKeepsFoldersAndRequests() async throws {
        let app = try TestApp.make(isPro: true)
        await app.load()
        let json = """
            {"info":{"name":"Shop","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
             "item":[{"name":"Orders","item":[{"name":"List orders","request":{"method":"GET",
               "url":{"raw":"https://shop.example/orders?page=1"},"header":[{"key":"Accept","value":"application/json"}]}}]},
              {"name":"Create order","request":{"method":"POST","url":"https://shop.example/orders",
               "body":{"mode":"raw","raw":"{\\"sku\\":1}","options":{"raw":{"language":"json"}}}}}]}
            """
        let id = try #require(await app.importCollection(try PostmanImporter.importDocument(Data(json.utf8))))
        let tree = try #require(app.collection(id)?.tree)
        #expect(tree.folders.map(\.name) == ["Orders"])
        let names = tree.requests.map(\.request.name).sorted()
        #expect(names == ["Create order", "List orders"])
        let list = try #require(tree.requests.first { $0.request.name == "List orders" }).request
        #expect(list.headers.contains { $0.name == "Accept" })
        #expect(list.queryParams.contains { $0.name == "page" })
    }
}

@MainActor
@Suite("End to end: settings and diagnostics", .serialized)
struct EndToEndSettingsTests {
    // AC: X02.2
    @Test func followRedirectsDefaultAppliesToNewRequests() async throws {
        let app = try TestApp.make()
        await app.load()
        let id = try #require(await app.createCollection(named: "S"))
        app.preferences.followRedirects = false
        let reference = try #require(await app.createRequest(in: id, folderKey: nil))
        #expect(app.request(reference)?.request.settings.followRedirects == false)
        app.preferences.followRedirects = true
        let second = try #require(await app.createRequest(in: id, folderKey: nil))
        #expect(app.request(second)?.request.settings.followRedirects == true)
    }

    // AC: X04.3
    @Test func diagnosticsReportHasNoPathsQueriesOrSecrets() async throws {
        let echo = try await EchoApp()
        defer { Task { await echo.stop() } }
        _ = try await echo.send(RequestItem(name: "D", url: "\(echo.base)/private/path?token=abc123"))
        let report = await echo.app.environment.diagnostics.makeReport().text
        #expect(!report.isEmpty)
        #expect(!report.contains("/private/path"))
        #expect(!report.contains("abc123"))
    }
}

@MainActor
@Suite("Diagnostics export")
struct DiagnosticsExportTests {
    // AC: X04.3
    @Test func reportIsWrittenAsATextFile() throws {
        let url = try #require(DiagnosticsSheet.write("RequestPad diagnostics\nline 2"))
        #expect(url.lastPathComponent == "RequestPad Diagnostics.txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "RequestPad diagnostics\nline 2")
    }
}

@MainActor
@Suite("App launch")
struct AppLaunchTests {
    /// On macOS the window, the menu bar item, Shortcuts and Services all load the model at launch. Overlapping loads
    /// must share one start-up (one Local Echo, one store start) and an existing purchase is not a new unlock.
    @Test func overlappingLoadsShareOneStartupAndDoNotAnnounceExistingPro() async throws {
        let app = try TestApp.makeLive(isPro: true)
        async let first: Void = app.load()
        async let second: Void = app.load()
        async let third: Void = app.load()
        _ = await (first, second, third)
        #expect(app.isLoaded)
        #expect(app.entitlements.isPro)
        #expect(!app.store.didUnlockPro)
        let port = app.echoPort
        await app.load()
        #expect(app.echoPort == port)
        await app.stopEcho()
    }
}
