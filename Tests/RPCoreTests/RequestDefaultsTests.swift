import Testing

@testable import RPCore

@Suite("RequestDefaults")
struct RequestDefaultsTests {
    @Test func defaults() {
        #expect(RequestDefaults.timeout == .seconds(30))
        #expect(RequestDefaults.maximumRedirects == 10)
        #expect(RequestDefaults.maximumRenderedBodyBytes == 10_485_760)
        #expect(RequestDefaults.timeoutRange.contains(RequestDefaults.timeout))
    }

    @Test(arguments: [
        (Duration.zero, Duration.seconds(1)),
        (.milliseconds(500), .seconds(1)),
        (.seconds(1), .seconds(1)),
        (.seconds(45), .seconds(45)),
        (.seconds(600), .seconds(600)),
        (.seconds(601), .seconds(600)),
        (.seconds(-5), .seconds(1)),
    ])
    func clamping(input: Duration, expected: Duration) {
        #expect(RequestDefaults.clampedTimeout(input) == expected)
    }
}
