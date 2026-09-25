import Foundation
import Testing

@testable import RPServices

@Suite("Log")
struct LogTests {
    @Test(arguments: [
        ("https://user:secret@api.example.com/v1/users?token=abc#frag", "https://api.example.com"),
        ("http://localhost:8080/path", "http://localhost:8080"),
        ("http://[::1]:9000/x", "http://[::1]:9000"),
        ("HTTPS://Example.COM/", "https://example.com"),
    ])
    func redactionKeepsOnlySchemeHostPort(input: String, expected: String) throws {
        let url = try #require(URL(string: input))
        #expect(Log.redacted(url) == expected)
    }

    @Test(arguments: ["mailto:someone@example.com", "file:///Users/x/secret.txt", "/relative/path"])
    func urlsWithoutHostAreFullyRedacted(input: String) throws {
        let url = try #require(URL(string: input))
        #expect(Log.redacted(url) == "<redacted-url>")
    }

    @Test func everyCategoryProducesALogger() {
        for category in Log.Category.allCases {
            let logger = Log.logger(category)
            logger.debug("Log category self-test")
        }
        #expect(Set(Log.Category.allCases.map(\.rawValue)).count == Log.Category.allCases.count)
    }
}
