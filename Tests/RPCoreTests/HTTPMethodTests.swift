import Foundation
import Testing

@testable import RPCore

@Suite("HTTPMethod")
struct HTTPMethodTests {
    @Test(arguments: ["get", "Post", "PUT", "patch", "Delete", "HEAD", "options"])
    func standardMethodsNormalizeToUppercase(input: String) throws {
        let method = try #require(HTTPMethod(rawValue: input))
        #expect(method.rawValue == input.uppercased())
        #expect(method.isStandard)
    }

    @Test(arguments: ["PURGE", "PROPFIND", "x-custom", "M-SEARCH", "!#$%&'*+-.^_`|~"])
    func customTokensAreAcceptedAndKeepCase(input: String) throws {
        let method = try #require(HTTPMethod(rawValue: input))
        #expect(method.rawValue == input)
        #expect(!method.isStandard)
    }

    @Test(arguments: ["", "GET ", "GE T", "GÉT", "GET\n", "(GET)", "a/b", "\"GET\"", String(repeating: "A", count: 33)])
    func invalidTokensAreRejected(input: String) {
        #expect(HTTPMethod(rawValue: input) == nil)
    }

    @Test func maximumLengthTokenIsAccepted() {
        #expect(HTTPMethod(rawValue: String(repeating: "A", count: HTTPMethod.maximumLength)) != nil)
    }

    @Test func standardListOrder() {
        #expect(HTTPMethod.standard.map(\.rawValue) == ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
    }

    @Test func bodyConvention() throws {
        #expect(HTTPMethod.post.conventionallyHasBody)
        #expect(HTTPMethod.put.conventionallyHasBody)
        #expect(HTTPMethod.patch.conventionallyHasBody)
        #expect(!HTTPMethod.get.conventionallyHasBody)
        #expect(!HTTPMethod.head.conventionallyHasBody)
        #expect(try #require(HTTPMethod(rawValue: "PURGE")).conventionallyHasBody)
    }

    @Test func codableRoundTrip() throws {
        let methods = [HTTPMethod.get, try #require(HTTPMethod(rawValue: "PROPFIND"))]
        let data = try JSONEncoder().encode(methods)
        #expect(String(decoding: data, as: UTF8.self) == #"["GET","PROPFIND"]"#)
        #expect(try JSONDecoder().decode([HTTPMethod].self, from: data) == methods)
    }

    @Test func decodingInvalidTokenThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([HTTPMethod].self, from: Data(#"["BAD METHOD"]"#.utf8))
        }
    }

    @Test func descriptionIsRawValue() {
        #expect(HTTPMethod.delete.description == "DELETE")
    }
}
