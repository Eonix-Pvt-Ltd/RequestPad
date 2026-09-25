import Testing

@testable import RPCore

@Suite("HTTPStatusClass")
struct HTTPStatusClassTests {
    @Test(arguments: [
        (100, HTTPStatusClass.informational), (199, .informational),
        (200, .success), (204, .success), (299, .success),
        (301, .redirection), (399, .redirection),
        (400, .clientError), (404, .clientError), (499, .clientError),
        (500, .serverError), (599, .serverError),
        (0, .nonStandard), (99, .nonStandard), (600, .nonStandard), (-1, .nonStandard),
    ])
    func classification(code: Int, expected: HTTPStatusClass) {
        #expect(HTTPStatusClass(statusCode: code) == expected)
    }

    @Test(arguments: HTTPStatusClass.allCases)
    func everyClassHasAName(statusClass: HTTPStatusClass) {
        #expect(!statusClass.localizedName.isEmpty)
    }

    @Test func namesAreDistinct() {
        let names = Set(HTTPStatusClass.allCases.map(\.localizedName))
        #expect(names.count == HTTPStatusClass.allCases.count)
    }
}
