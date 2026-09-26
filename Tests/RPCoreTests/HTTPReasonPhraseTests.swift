import Testing

@testable import RPCore

@Suite("HTTP reason phrases")
struct HTTPReasonPhraseTests {
    @Test(arguments: [
        (200, "OK"), (201, "Created"), (204, "No Content"), (301, "Moved Permanently"), (404, "Not Found"),
        (418, "I'm a Teapot"), (429, "Too Many Requests"), (500, "Internal Server Error"), (503, "Service Unavailable"),
    ])
    func registeredCodesUseTheStandardPhrase(code: Int, phrase: String) {
        #expect(HTTPReasonPhrase.phrase(for: code) == phrase)
    }

    @Test func unregisteredCodesHaveNoPhrase() {
        #expect(HTTPReasonPhrase.phrase(for: 299).isEmpty)
        #expect(HTTPReasonPhrase.phrase(for: 999).isEmpty)
        #expect(HTTPReasonPhrase.phrase(for: -1).isEmpty)
    }

    @Test func everyPhraseBelongsToAValidStatusClass() {
        for code in HTTPReasonPhrase.phrases.keys {
            #expect(HTTPStatusClass(statusCode: code) != .nonStandard)
        }
    }
}
