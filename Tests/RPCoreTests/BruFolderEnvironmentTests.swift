import Foundation
import Testing

@testable import RPCore

@Suite("BruFolderCodec")
struct BruFolderCodecTests {
    @Test func brunoCollectionFileRoundTripsExactly() throws {
        let text = try FixtureLoader.text("bru/bruno/collection.bru")
        let (folder, document) = try BruFolderCodec.decode(text)
        #expect(folder.settings.auth == .none)
        #expect(folder.settings.headers.map(\.name) == ["content-type", "Authorization", "transaction-id"])
        #expect(folder.settings.variables.map(\.isEnabled) == [true, false])
        #expect(folder.settings.docs == "This request needs auth token to be set in the headers.")
        #expect(folder.hasUnsupportedScripts)
        #expect(folder.name == nil)
        #expect(try BruFolderCodec.encode(folder.settings, name: nil, preserving: document) == text)
    }

    @Test func changingAuthModeUpdatesModeAndReusesExistingBlock() throws {
        let text = try FixtureLoader.text("bru/bruno/collection.bru")
        let (folder, document) = try BruFolderCodec.decode(text)
        var settings = folder.settings
        settings.auth = .bearer(token: "{{token}}")
        let output = try BruFolderCodec.encode(settings, name: nil, preserving: document)
        #expect(output.contains("auth {\n  mode: bearer\n}"))
        #expect(output.contains("auth:bearer {\n  token: {{token}}\n}"))
        #expect(output.contains("auth:basic {\n  username: john"))
        #expect(output.contains("script:post-response {"))
        #expect(try BruFolderCodec.decode(output).folder.settings.auth == .bearer(token: "{{token}}"))
    }

    @Test func freshFolderFile() throws {
        let settings = FolderSettings(
            headers: [KeyValue(name: "X-Team", value: "core")],
            auth: .apiKey(APIKeyAuth(key: "k", value: "v", placement: .query)),
            variables: [KeyValue(name: "region", value: "eu")], docs: "Admin endpoints", sequence: 2)
        let text = try BruFolderCodec.encode(settings, name: "Admin")
        #expect(
            text.hasPrefix(
                "meta {\n  name: Admin\n  seq: 2\n}\n\nheaders {\n  X-Team: core\n}\n\nauth {\n  mode: apikey\n}"))
        let (decoded, _) = try BruFolderCodec.decode(text)
        #expect(decoded.name == "Admin")
        #expect(decoded.settings == settings)
        #expect(!decoded.hasUnsupportedScripts)
    }

    @Test func missingAuthBlockMeansInherit() throws {
        let (decoded, _) = try BruFolderCodec.decode("meta {\n  name: F\n}\n")
        #expect(decoded.settings.auth == .inherit)
        #expect(try BruFolderCodec.encode(decoded.settings, name: "F") == "meta {\n  name: F\n}\n")
    }
}

@Suite("BruEnvironmentCodec")
struct BruEnvironmentCodecTests {
    let key = "collection-1/environments/Staging.bru"

    @Test func decodesPlainSecretAndPreservedBlocks() throws {
        let text = try FixtureLoader.text("bru/environments/Staging.bru")
        let (environment, document) = try BruEnvironmentCodec.decode(text, name: "Staging", environmentKey: key)
        #expect(environment.name == "Staging")
        #expect(
            environment.variables.map(\.name) == [
                "baseUrl", "pageSize", "legacyHost", "certificate", "clientSecret", "oldToken", "apiKey",
            ])
        #expect(environment.variables.map(\.isEnabled) == [true, true, false, true, true, false, true])
        #expect(
            environment.variables[3].value
                == .plain(
                    "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC8\n-----END PUBLIC KEY-----"))
        #expect(environment.variables[4].value == .secret(SecretRef(account: "env:\(key):clientSecret")))
        #expect(environment.preservedBlocks.count == 1)
        #expect(try BruEnvironmentCodec.encode(environment, preserving: document) == text)
    }

    @Test func secretValuesNeverReachTheFile() throws {
        let text = try FixtureLoader.text("bru/environments/Staging.bru")
        var (environment, document) = try BruEnvironmentCodec.decode(text, name: "Staging", environmentKey: key)
        environment.variables.append(Variable(name: "newSecret", value: .secret(SecretRef(account: "whatever"))))
        environment.variables[0].value = .plain("https://staging2.example.com")
        let output = try BruEnvironmentCodec.encode(environment, preserving: document)
        #expect(output.contains("vars:secret [\n  clientSecret,\n  ~oldToken,\n  apiKey,\n  newSecret\n]"))
        #expect(output.contains("baseUrl: https://staging2.example.com"))
        #expect(output.contains("color {\n  value: #ff9500\n}"))
        #expect(!output.contains("whatever"))
        document = try BruDocument.parse(output)
        #expect(document.blocks.map(\.name) == ["vars", "vars:secret", "color"])
    }

    @Test func freshEnvironmentAndRemovingAllSecrets() throws {
        let environment = Environment(
            name: "Local",
            variables: [
                .plain("host", "localhost:8080"), Variable(name: "token", value: .secret(SecretRef(account: "a"))),
            ])
        let fresh = try BruEnvironmentCodec.encode(environment)
        #expect(fresh == "vars {\n  host: localhost:8080\n}\n\nvars:secret [\n  token\n]\n")
        let (decoded, document) = try BruEnvironmentCodec.decode(fresh, name: "Local", environmentKey: "k")
        #expect(decoded.variables.map(\.name) == ["host", "token"])
        var withoutSecrets = decoded
        withoutSecrets.variables.removeLast()
        #expect(
            try BruEnvironmentCodec.encode(withoutSecrets, preserving: document)
                == "vars {\n  host: localhost:8080\n}\n\n")
    }

    @Test func emptyAndSecretOnlyFiles() throws {
        let (empty, _) = try BruEnvironmentCodec.decode("", name: "E", environmentKey: "k")
        #expect(empty.variables.isEmpty)
        let (secretOnly, document) = try BruEnvironmentCodec.decode("vars:secret [ ]\n", name: "S", environmentKey: "k")
        #expect(secretOnly.variables.isEmpty)
        var added = secretOnly
        added.variables = [.plain("a", "1")]
        #expect(try BruEnvironmentCodec.encode(added, preserving: document) == "vars {\n  a: 1\n}\n")
    }
}

@Suite("BrunoManifest")
struct BrunoManifestTests {
    @Test func decodesAndPreservesUnknownKeys() throws {
        let json =
            #"{"version":"1","name":"Shop API","type":"collection","ignore":["node_modules"],"scripts":{"flow":"sandwich"}}"#
        var manifest = try BrunoManifest.decode(Data(json.utf8))
        #expect(manifest.name == "Shop API")
        #expect(manifest.ignore == ["node_modules"])
        manifest.name = "Shop API v2"
        let output = String(decoding: manifest.encoded(), as: UTF8.self)
        #expect(output.contains("\"name\": \"Shop API v2\""))
        #expect(output.contains("\"flow\": \"sandwich\""))
    }

    @Test func newManifest() throws {
        let data = BrunoManifest(name: "New").encoded()
        let decoded = try BrunoManifest.decode(data)
        #expect(decoded.name == "New")
        #expect(decoded.version == "1")
        #expect(decoded.ignore == ["node_modules", ".git"])
    }

    @Test(arguments: [#"[]"#, #"{"version":"1"}"#, #"{"name":""}"#, #"{"name":"x","type":"workspace"}"#, "not json"])
    func invalidManifests(json: String) {
        #expect(throws: CoreError.self) { try BrunoManifest.decode(Data(json.utf8)) }
    }
}
