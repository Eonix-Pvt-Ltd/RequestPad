import Foundation
import RPCore
import RPData

/// "Load Sample Data" (F08.3, A12): a Sample collection that exercises every feature against Local Echo, a "Local"
/// environment and the `echoBaseURL` global. Stable ids make loading it twice idempotent.
public enum SampleData {
    public static let collectionID = UUID(uuidString: "5A3F1E00-0000-4000-8000-000000000001") ?? UUID()
    public static let environmentID = UUID(uuidString: "5A3F1E00-0000-4000-8000-000000000002") ?? UUID()
    public static let globalsID = UUID(uuidString: "5A3F1E00-0000-4000-8000-000000000003") ?? UUID()
    static let basicsFolderID = UUID(uuidString: "5A3F1E00-0000-4000-8000-000000000010") ?? UUID()
    static let authFolderID = UUID(uuidString: "5A3F1E00-0000-4000-8000-000000000011") ?? UUID()
    static let chainingFolderID = UUID(uuidString: "5A3F1E00-0000-4000-8000-000000000012") ?? UUID()

    public static let echoVariable = "echoBaseURL"

    /// Writes the sample collection into `store` and sets `echoBaseURL` in the globals.
    public static func install(into store: LocalStore, echoBaseURL: URL) async throws(DataError) {
        try await store.createCollection(
            name: String(localized: "Sample", bundle: .module), storage: .sample,
            settings: FolderSettings(headers: [KeyValue(name: "X-Client", value: "RequestPad Sample")]),
            id: collectionID)
        let folders: [(UUID, String, FolderSettings)] = [
            (basicsFolderID, "Basics", FolderSettings()),
            (authFolderID, "Auth", FolderSettings()),
            (chainingFolderID, "Chaining", FolderSettings(docs: "Run this folder with the collection runner.")),
        ]
        for (offset, folder) in folders.enumerated() {
            try await store.upsertFolder(
                RequestFolder(id: folder.0, name: folder.1, path: folder.1, settings: folder.2), parentID: nil,
                in: collectionID, sortOrder: offset)
        }
        for (folderID, request) in requests() {
            try await store.upsertRequest(request, folderID: folderID, in: collectionID)
        }
        try await store.upsertEnvironment(
            Environment(
                id: environmentID, name: "Local", variables: [.plain("userName", "Ada"), .plain("pageSize", "20")]),
            for: collectionID)
        var globals = try await store.environments(for: nil).first ?? Environment(id: globalsID, name: "Globals")
        globals.variables.removeAll { $0.name == echoVariable }
        globals.variables.append(.plain(echoVariable, echoBaseURL.absoluteString))
        try await store.upsertEnvironment(globals, for: nil)
    }

    static func request(_ index: Int, _ name: String, _ build: (inout RequestItem) -> Void) -> RequestItem {
        var request = RequestItem(
            id: UUID(uuidString: String(format: "5A3F1E00-0000-4000-8000-%012d", 100 + index)) ?? UUID(), name: name,
            sortOrder: index)
        build(&request)
        return request
    }

    static func requests() -> [(UUID?, RequestItem)] {
        let base = "{{\(echoVariable)}}"
        return [
            (
                basicsFolderID,
                request(1, "Echo a GET") {
                    $0.url = "\(base)/echo?page=1&size={{pageSize}}"
                    $0.queryParams = [
                        KeyValue(name: "page", value: "1"), KeyValue(name: "size", value: "{{pageSize}}"),
                    ]
                    $0.headers = [KeyValue(name: "Accept", value: "application/json")]
                }
            ),
            (
                basicsFolderID,
                request(2, "Create JSON") {
                    $0.method = .post
                    $0.url = "\(base)/users"
                    $0.body = .json("{\n  \"name\": \"{{userName}}\",\n  \"roles\": [\"admin\", \"dev\"]\n}")
                    $0.assertions = [Assertion(source: .status, operation: .equals, operand: "200")]
                }
            ),
            (
                basicsFolderID,
                request(3, "Form login") {
                    $0.method = .post
                    $0.url = "\(base)/login"
                    $0.body = .formURLEncoded([
                        KeyValue(name: "user", value: "{{userName}}"), KeyValue(name: "remember", value: "true"),
                    ])
                }
            ),
            (
                basicsFolderID,
                request(4, "Not found (404)") {
                    $0.url = "\(base)/status/404"
                    $0.assertions = [Assertion(source: .status, operation: .equals, operand: "404")]
                }
            ),
            (basicsFolderID, request(5, "Slow response") { $0.url = "\(base)/delay/1500" }),
            (basicsFolderID, request(6, "Image preview") { $0.url = "\(base)/image.png" }),
            (basicsFolderID, request(7, "Large body (12 MB)") { $0.url = "\(base)/bytes/12582912" }),
            (basicsFolderID, request(8, "Follow redirects") { $0.url = "\(base)/redirect/3" }),
            (
                authFolderID,
                request(9, "Bearer token") {
                    $0.url = "\(base)/secure"
                    $0.auth = .bearer(token: "{{userName}}-token")
                }
            ),
            (
                authFolderID,
                request(10, "OAuth 2.0 client credentials") {
                    $0.url = "\(base)/protected"
                    $0.auth = .oauth2(
                        OAuth2Config(
                            grantType: .clientCredentials, accessTokenURL: "\(base)/oauth/token",
                            clientID: "requestpad-sample",
                            clientSecret: "sample-secret", scope: "read", credentialsPlacement: .body))
                }
            ),
            (authFolderID, request(11, "Set cookies") { $0.url = "\(base)/cookies/set?session=sample&theme=dark" }),
            (
                chainingFolderID,
                request(12, "1. Get a token") {
                    $0.method = .post
                    $0.url = "\(base)/oauth/token"
                    $0.body = .formURLEncoded([
                        KeyValue(name: "grant_type", value: "client_credentials"),
                        KeyValue(name: "client_id", value: "sample"),
                    ])
                    $0.extractors = [Extractor(variableName: "accessToken", source: .body(path: "$.access_token"))]
                    $0.assertions = [
                        Assertion(source: .status, operation: .equals, operand: "200"),
                        Assertion(source: .body(path: "$.access_token"), operation: .exists),
                    ]
                }
            ),
            (
                chainingFolderID,
                request(13, "2. Use the token") {
                    $0.url = "\(base)/me"
                    $0.auth = .bearer(token: "{{accessToken}}")
                    $0.assertions = [
                        Assertion(
                            source: .body(path: "$.headers.Authorization"), operation: .contains, operand: "echo-")
                    ]
                }
            ),
            (
                nil,
                request(14, "GraphQL query") {
                    $0.kind = .graphql
                    $0.method = .post
                    $0.url = "\(base)/graphql"
                    $0.body = .graphQL(
                        GraphQLBody(
                            query: "query Items($first: Int) {\n  items(first: $first) {\n    id\n    name\n  }\n}",
                            variables: "{\n  \"first\": 5\n}"))
                }
            ),
        ]
    }
}
