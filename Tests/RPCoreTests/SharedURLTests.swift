import Testing

@testable import RPCore

@Suite("SharedURL")
struct SharedURLTests {
    @Test(arguments: [
        ("https://api.example.com/users?id=1", "https://api.example.com/users?id=1"),
        ("  http://example.com  ", "http://example.com"),
        ("<https://example.com/a>", "https://example.com/a"),
        ("\"https://example.com\"", "https://example.com"),
        ("`https://example.com/x`", "https://example.com/x"),
        ("api.example.com/v1/items", "https://api.example.com/v1/items"),
        ("localhost:8080/health", "http://localhost:8080/health"),
        ("192.168.1.20:3000", "http://192.168.1.20:3000"),
        ("https://example.com\nsecond line", "https://example.com"),
        ("HTTPS://Example.com", "HTTPS://Example.com"),
    ])
    func accepts(input: String, expected: String) {
        #expect(SharedURL.url(from: input) == expected)
    }

    @Test(arguments: [
        "", "   ", "hello world", "file:///etc/passwd", "javascript:alert(1)", "mailto:a@example.com",
        "ftp://example.com", "https://", "https:// example.com", "not-a-host", "http://exa mple.com",
    ])
    func rejects(input: String) {
        #expect(SharedURL.url(from: input) == nil)
    }

    @Test func rejectsHugeSelections() {
        #expect(
            SharedURL.url(from: "https://example.com/" + String(repeating: "a", count: SharedURL.maximumLength)) == nil)
    }

    @Test func namesRequestsAfterTheHost() {
        #expect(SharedURL.requestName(for: "https://api.example.com/x") == "api.example.com")
        #expect(SharedURL.requestName(for: "::") == "::")
    }
}
