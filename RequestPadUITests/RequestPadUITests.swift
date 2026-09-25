import XCTest

final class RequestPadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Smoke test: the app launches and shows its root navigation (Phase 1 exit).
    @MainActor
    func testLaunchShowsRootNavigation() throws {
        let app = XCUIApplication()
        app.launch()
        let emptySidebar = app.descendants(matching: .any)["root.sidebar.empty"]
        let emptyDetail = app.descendants(matching: .any)["root.detail.empty"]
        XCTAssertTrue(
            emptySidebar.waitForExistence(timeout: 10) || emptyDetail.waitForExistence(timeout: 1),
            "Root navigation did not appear")
    }

    /// Accessibility audit of the launch screen (B8). Later phases extend this to every screen.
    @MainActor
    func testLaunchScreenPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        var verified: [AccessibilityAudit.VerifiedExemption] = []
        #if os(iOS)
            verified.append(
                .init(
                    auditType: .textClipped, identifier: "root.sidebar.empty",
                    evidence: "SDLC_LOG Phase 1: wraps without clipping at accessibility-extra-extra-extra-large"))
        #endif
        try AccessibilityAudit.run(on: app, verified: verified)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
