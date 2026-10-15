import Foundation
import Testing

@testable import RPCore

@Suite("Models")
struct ModelTests {
    @Test func keyValueEqualityIgnoresIdentity() {
        let lhs = KeyValue(name: "a", value: "1")
        let rhs = KeyValue(name: "a", value: "1")
        #expect(lhs.id != rhs.id)
        #expect(lhs == rhs)
        #expect(Set([lhs, rhs]).count == 1)
        #expect(lhs != KeyValue(name: "a", value: "1", isEnabled: false))
        let rows = [
            KeyValue(name: "Accept", value: "a"), KeyValue(name: "accept", value: "b"),
            KeyValue(name: "ACCEPT", value: "c", isEnabled: false), KeyValue(name: "", value: "x"),
        ]
        #expect(rows.active.count == 2)
        #expect(rows.lastValue(forCaseInsensitiveName: "ACCEPT") == "b")
        #expect(rows.lastValue(forCaseInsensitiveName: "missing") == nil)
    }

    @Test func multipartAndVariableEquality() {
        let field = MultipartField(name: "f", content: .files(["a"]))
        #expect(field == MultipartField(name: "f", content: .files(["a"])))
        #expect(Set([field, MultipartField(name: "f", content: .files(["a"]))]).count == 1)
        let variable = Variable.plain("v", "1")
        #expect(variable == Variable.plain("v", "1"))
        #expect(Set([variable, Variable.plain("v", "1")]).count == 1)
        let extractor = Extractor(variableName: "x", source: .status)
        #expect(Set([extractor, Extractor(variableName: "x", source: .status)]).count == 1)
        let assertion = Assertion(source: .status, operation: .equals, operand: "200")
        #expect(Set([assertion, Assertion(source: .status, operation: .equals, operand: "200")]).count == 1)
        #expect(Environment(name: "E").variables.isEmpty)
    }

    @Test(
        arguments: [
            (RequestBody.none, "none", nil), (.json("{}"), "json", "application/json"),
            (.text(""), "text", "text/plain; charset=utf-8"),
            (.xml(""), "xml", "application/xml"),
            (.formURLEncoded([]), "formUrlEncoded", "application/x-www-form-urlencoded"),
            (.multipart([]), "multipartForm", nil), (.graphQL(GraphQLBody()), "graphql", "application/json"),
            (.unsupported(mode: "sparql"), "sparql", nil),
        ] as [(RequestBody, String, String?)])
    func bodyModes(body: RequestBody, mode: String, contentType: String?) {
        #expect(body.bruMode == mode)
        #expect(body.defaultContentType == contentType)
    }

    @Test(
        arguments: [
            (RequestAuth.inherit, "inherit"), (.none, "none"), (.bearer(token: ""), "bearer"),
            (.basic(username: "", password: ""), "basic"),
            (.apiKey(APIKeyAuth(key: "", value: "")), "apikey"),
            (.oauth2(OAuth2Config(grantType: .clientCredentials)), "oauth2"),
            (.unsupported(mode: "digest"), "digest"),
        ] as [(RequestAuth, String)])
    func authModes(auth: RequestAuth, mode: String) {
        #expect(auth.bruMode == mode)
    }

    @Test func requestContentComparisonAndCodable() throws {
        var request = RequestItem(
            name: "r", url: "https://h", headers: [KeyValue(name: "a", value: "b")], body: .json("{}"))
        var copy = request
        copy.id = UUID()
        #expect(request.hasSameContent(as: copy))
        copy.url = "https://other"
        #expect(!request.hasSameContent(as: copy))
        request.extractors = [Extractor(variableName: "t", source: .body(path: "$.t"))]
        request.assertions = [Assertion(source: .header("etag"), operation: .exists)]
        let decoded = try JSONDecoder().decode(RequestItem.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        let entry = HistoryEntry(
            request: request, response: ResponseSummary(statusCode: 200, durationMilliseconds: 12, sizeBytes: 3),
            sentAt: Date(timeIntervalSince1970: 0))
        #expect(try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry)) == entry)
        let folder = RequestFolder(name: "F", path: "a/F")
        #expect(folder.settings == FolderSettings())
        #expect([CollectionStorage.native, .folder, .sample].map(\.rawValue) == ["native", "folder", "sample"])
    }

    @Test(arguments: [
        CoreError.inputTooLarge(limitBytes: 1024), .nestingTooDeep(limit: 5),
        .jsonSyntax(position: TextPosition(line: 1, column: 2), reason: "r"),
        .yamlSyntax(position: TextPosition(line: 3, column: 4), reason: "r"),
        .bruSyntax(position: TextPosition(line: 5, column: 1), reason: "r"),
        .curlSyntax(reason: "r"), .invalidJSONPath(reason: "r"), .unsupportedDocument(reason: "r"),
        .invalidDocument(path: "p", reason: "r"),
        .invalidRequest(reason: "r"),
    ])
    func coreErrorsArePresentable(error: CoreError) {
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.recoverySuggestion?.isEmpty == false)
    }

    @Test func textPositionDescription() {
        #expect(TextPosition(line: 3, column: 7).description == "3:7")
        #expect(
            CoreError.jsonSyntax(position: TextPosition(line: 3, column: 7), reason: "bad").errorDescription?.contains(
                "line 3, column 7") == true)
    }
}
