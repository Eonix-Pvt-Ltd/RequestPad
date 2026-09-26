import XCTest

/// App Store screenshots for iPhone and iPad (run by `scripts/screenshots.sh`, which exports the attachments).
/// Each scene is staged by the app's Debug-only `-ScreenshotScenario` through its normal flows (Guideline 2.3).
final class ScreenshotTests: XCTestCase {
    /// Scenario name and an element that shows the scene is ready.
    private static let scenes: [(name: String, ready: String)] = [
        ("response", "response.status"),
        ("chaining", "extract.add"),
        ("graphql", "graphql.completions"),
        ("runner", "runner.summary"),
        ("environments", "environments.add"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        for (index, scene) in Self.scenes.enumerated() {
            let app = XCUIApplication()
            app.launchArguments = [
                "-UITestMode", "-UITestPro", "-ScreenshotScenario", scene.name, "-ApplePersistenceIgnoreState", "YES",
            ]
            app.launch()
            let ready = app.descendants(matching: .any)[scene.ready].firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 30), "Scene \(scene.name) did not become ready")
            // Let sheet presentation, scrolling and the send spinner settle.
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = String(format: "appstore-%02d-%@", index + 1, scene.name)
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
}
