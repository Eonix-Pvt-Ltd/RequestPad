import Foundation
import Testing

@testable import RPCore

@Suite("OpenAPIImporter")
struct OpenAPIImporterTests {
    func request(_ collection: ImportedCollection, _ name: String) throws -> RequestItem {
        try #require(collection.items.first(where: { $0.request.name == name })?.request)
    }

    @Test func importsPetstoreYAML() throws {
        let collection = try OpenAPIImporter.importDocument(try FixtureLoader.data("openapi/petstore.yaml"))
        #expect(collection.name == "Swagger Petstore")
        #expect(collection.settings.variables == [KeyValue(name: "baseUrl", value: "https://petstore.example.com/v1")])
        #expect(collection.environments.map(\.name) == ["Production", "Server 2"])
        #expect(collection.settings.auth == .bearer(token: "{{bearerToken}}"))
        #expect(collection.folders.map(\.path) == ["pets", "files"])
        #expect(collection.items.count == 7)

        let list = try request(collection, "List all pets")
        #expect(list.url == "{{baseUrl}}/pets")
        #expect(list.queryParams == [KeyValue(name: "limit", value: "20", isEnabled: false)])
        #expect(list.headers == [KeyValue(name: "X-Trace-Id", value: "", isEnabled: false)])
        #expect(list.auth == .inherit)

        let create = try request(collection, "Create a pet")
        guard case .json(let body) = create.body else {
            Issue.record("Expected JSON body")
            return
        }
        let example = try JSONParser().parse(body)
        #expect(example["name"] == .string("string"))
        #expect(example["vaccinated"] == .bool(false))
        #expect(example["owner"]?["pets"]?[0] == .null, "cycle must stop")

        let show = try request(collection, "Info for a specific pet")
        #expect(show.url == "{{baseUrl}}/pets/:petId")
        #expect(show.pathParams == [KeyValue(name: "petId", value: "")])
        let delete = try request(collection, "deletePet")
        #expect(delete.auth == RequestAuth.none)
        let inventory = try request(collection, "getInventory")
        #expect(inventory.auth == .apiKey(APIKeyAuth(key: "api_key", value: "{{apiKey}}")))
        let login = try request(collection, "Log in")
        #expect(
            login.body
                == .formURLEncoded([KeyValue(name: "username", value: "ann"), KeyValue(name: "password", value: "")]))
        let upload = try request(collection, "uploadFile")
        #expect(
            upload.body
                == .multipart([
                    MultipartField(name: "file", content: .files([])),
                    MultipartField(name: "note", content: .text("string")),
                ]))
        #expect(collection.items.first(where: { $0.request.name == "uploadFile" })?.folderPath == "files")
    }

    @Test func importsOpenAPI31JSON() throws {
        let collection = try OpenAPIImporter.importDocument(try FixtureLoader.data("openapi/inventory-3.1.json"))
        #expect(collection.settings.variables.first?.value == "https://eu.inventory.example.com/v2")
        #expect(
            collection.environments.map { $0.variables.first?.value } == [
                .plain("https://eu.inventory.example.com/v2"), .plain("http://localhost:3000"),
            ])
        guard case .oauth2(let config) = collection.settings.auth else {
            Issue.record("Expected OAuth2")
            return
        }
        #expect(config.grantType == .authorizationCode)
        #expect(config.scope == "inventory:read")
        #expect(config.authorizationURL == "https://auth.example.com/authorize")
        #expect(collection.folders.map(\.path) == ["Items-Admin"])

        let list = try request(collection, "listItems")
        #expect(list.url == "{{baseUrl}}/items?q=all")
        #expect(list.queryParams == [KeyValue(name: "q", value: "all")])
        #expect(list.headers == [KeyValue(name: "X-Tenant", value: "acme", isEnabled: false)])
        let create = try request(collection, "Create item")
        #expect(create.auth == RequestAuth.none)
        #expect(create.body == .json("{\n  \"name\": \"Bolt\",\n  \"qty\": 10\n}"))

        let part = try request(collection, "Replace part")
        #expect(part.url == "{{baseUrl}}/items/:itemId/parts/:partId")
        #expect(part.pathParams == [KeyValue(name: "itemId", value: "7"), KeyValue(name: "partId", value: "")])
        guard case .json(let partBody) = part.body else {
            Issue.record("Expected JSON")
            return
        }
        let example = try JSONParser().parse(partBody)
        #expect(example["id"] == .string("00000000-0000-0000-0000-000000000000"))
        #expect(example["createdAt"] == .string("2024-01-01T00:00:00Z"))
        #expect(example["tags"] == .array([.string("string")]))
        #expect(example["kind"] == .string("screw"))
        #expect(example["parent"] == .null)
        #expect(example["weird~key/name"] == .number("3"))

        let reports = try request(collection, "POST /reports")
        #expect(reports.auth == .basic(username: "{{username}}", password: "{{password}}"))
        #expect(reports.body == .text("a,b\n1,2"))
        #expect(try request(collection, "POST /xml").body == .xml("<item id=\"1\"/>"))
        #expect(try request(collection, "POST /binary").body == RequestBody.none)
        #expect(collection.notices.contains { $0.contains("Cookie parameters") })
        #expect(collection.notices.contains { $0.contains("application/octet-stream") })
    }

    @Test(arguments: [
        (#"{"swagger":"2.0"}"#, "Swagger"), (#"{"openapi":"4.0.0"}"#, "3.0"), ("[]", "object"),
        (##"{"openapi":"3.0.0","paths":{"/a":{"get":{"requestBody":{"$ref":"other.yaml#/x"}}}}}"##, "External"),
        (
            ##"{"openapi":"3.0.0","paths":{"/a":{"$ref":"#/components/pathItems/A"}},"components":{"pathItems":{"A":{"$ref":"#/components/pathItems/A"}}}}"##,
            "Circular"
        ),
        (##"{"openapi":"3.0.0","paths":{"/a":{"$ref":"#/nothing/here"}}}"##, "nothing"),
        ("openapi: 3.0.0\npaths:\n  /a:\n   get: [", "YAML"),
    ])
    func rejectsInvalidDocuments(document: String, hint: String) {
        #expect(throws: CoreError.self) { try OpenAPIImporter.importDocument(Data(document.utf8)) }
    }

    @Test func minimalDocumentsProduceNotices() throws {
        let noPaths = try OpenAPIImporter.importDocument(Data(#"{"openapi":"3.0.1","info":{"title":" "}}"#.utf8))
        #expect(noPaths.name == "Imported API")
        #expect(noPaths.settings.variables.first?.value == "http://localhost")
        #expect(noPaths.notices.count == 2)
        let relative = try OpenAPIImporter.importDocument(
            Data("openapi: 3.0.0\nservers:\n  - url: /api/\npaths:\n  /x:\n    get: {}\n".utf8))
        #expect(relative.settings.variables.first?.value == "/api")
        #expect(relative.notices.contains { $0.contains("relative") })
        #expect(relative.items.first?.request.name == "GET /x")
    }

    @Test func tooLargeDocumentsAreRejected() {
        let big = Data(repeating: 0x20, count: StructuredDocument.maximumBytes + 1)
        #expect(throws: CoreError.inputTooLarge(limitBytes: StructuredDocument.maximumBytes)) {
            try OpenAPIImporter.importDocument(big)
        }
    }
}

@Suite("PostmanImporter")
struct PostmanImporterTests {
    @Test func importsShopCollection() throws {
        let collection = try PostmanImporter.importDocument(
            try FixtureLoader.data("postman/shop.postman_collection.json"))
        #expect(collection.name == "Shop API")
        #expect(collection.settings.auth == .bearer(token: "{{token}}"))
        #expect(
            collection.settings.variables == [
                KeyValue(name: "baseUrl", value: "https://shop.example.com"), KeyValue(name: "retries", value: "3"),
            ])
        #expect(collection.folders.map(\.path) == ["Catalog", "Catalog/Nested"])
        #expect(collection.folders[0].settings.auth == .apiKey(APIKeyAuth(key: "X-Key", value: "{{apiKey}}")))
        let names = collection.items.map(\.request.name)
        #expect(
            names == [
                "List products", "Product by id", "Create order", "Upload", "Login", "GraphQL", "Digest", "Bare",
                "File body", "Raw text",
            ])
        func item(_ name: String) throws -> RequestItem {
            try #require(collection.items.first { $0.request.name == name }?.request)
        }

        let list = try item("List products")
        #expect(list.url == "{{baseUrl}}/products?page=1&size=20")
        #expect(list.queryParams.map(\.isEnabled) == [true, true, false])
        #expect(list.headers.map(\.isEnabled) == [true, false])
        #expect(list.auth == .inherit)
        #expect(collection.items[1].folderPath == "Catalog/Nested")
        let byID = try item("Product by id")
        #expect(byID.pathParams == [KeyValue(name: "id", value: "42")])
        #expect(byID.auth == RequestAuth.none)

        let order = try item("Create order")
        #expect(order.body == .json("{\n  \"sku\": \"A-1\"\n}"))
        #expect(order.headers.isEmpty)
        #expect(order.docs == "Places an order.")

        let upload = try item("Upload")
        #expect(upload.auth == .basic(username: "ann", password: "{{pw}}"))
        #expect(
            upload.body
                == .multipart([
                    MultipartField(name: "note", content: .text("hello")),
                    MultipartField(name: "file", content: .files(["/Users/ann/a.png"]), contentType: "image/png"),
                    MultipartField(name: "off", content: .text("x"), isEnabled: false),
                ]))
        #expect(try item("Login").url == "https://auth.example.com/login")
        #expect(
            try item("Login").body
                == .formURLEncoded([KeyValue(name: "user", value: "ann"), KeyValue(name: "remember", value: "true")]))

        let graphQL = try item("GraphQL")
        #expect(graphQL.kind == .graphql)
        #expect(graphQL.body == .graphQL(GraphQLBody(query: "{ products { id } }", variables: "{\"n\":1}")))
        guard case .oauth2(let config) = graphQL.auth else {
            Issue.record("Expected OAuth2")
            return
        }
        #expect(config.grantType == .clientCredentials)
        #expect(config.credentialsPlacement == .body)
        #expect(try item("Digest").auth == RequestAuth.none)
        #expect(try item("Bare").queryParams == [KeyValue(name: "x", value: "1")])
        #expect(try item("File body").body == RequestBody.none)
        #expect(try item("Raw text").body == .text("hello"))

        #expect(collection.notices.contains("Collection-level scripts were not imported."))
        #expect(collection.notices.contains { $0.hasPrefix("Scripts were not imported for: List products") })
        #expect(collection.notices.contains { $0.contains("digest") })
        #expect(collection.notices.contains { $0.contains("binary file body") })
    }

    @Test func postmanV20AuthObjects() throws {
        let json = #"""
            {"info":{"name":"Old","schema":"https://schema.getpostman.com/json/collection/v2.0.0/collection.json"},
             "item":[{"name":"r","request":{"method":"GET","url":"https://h","auth":{"type":"basic","basic":{"username":"u","password":"p"}}}}]}
            """#
        let collection = try PostmanImporter.importDocument(Data(json.utf8))
        #expect(collection.items[0].request.auth == .basic(username: "u", password: "p"))
    }

    @Test(arguments: [
        #"{"info":{"name":"x"}}"#,
        #"{"info":{"schema":"https://schema.getpostman.com/json/collection/v1.0.0/collection.json"}}"#,
        #"{"info":{"schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},"item":[{"name":"r","request":{"method":"BAD METHOD","url":"x"}}]}"#,
        "not json",
    ])
    func rejectsInvalidExports(json: String) {
        #expect(throws: CoreError.self) { try PostmanImporter.importDocument(Data(json.utf8)) }
    }

    @Test func folderDepthIsLimited() {
        var item = #"{"name":"leaf","request":{"url":"https://h"}}"#
        for _ in 0...PostmanImporter.maximumFolderDepth + 1 { item = #"{"name":"f","item":[\#(item)]}"# }
        let json =
            #"{"info":{"name":"deep","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},"item":[\#(item)]}"#
        #expect(throws: CoreError.self) { try PostmanImporter.importDocument(Data(json.utf8)) }
    }
}
