import XCTest

/// End-to-end flows against a clean, in-memory app (`-UITestMode`, Debug only). Each flow also runs the
/// accessibility audit on the screens it visits (B8) and attaches screenshots for review.
final class RequestPadUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    /// macOS restores the previous session's windows; the runner terminates the app between tests, which can save
    /// a state with no windows. Disabling restoration for test launches always opens a fresh main window
    /// (ADR-0037).
    private static let baseArguments = [
        "-UITestMode", "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Flows

    /// X02.1: onboarding is shown once, is skippable, and leads to the empty workspace.
    @MainActor
    func testOnboardingCanBeSkipped() throws {
        let app = launch()
        let skip = element(app, "onboarding.skip")
        XCTAssertTrue(skip.waitForExistence(timeout: Self.timeout), "Onboarding did not appear")
        attachScreenshot(app, named: "01-onboarding")
        try audit(app)
        skip.tap()
        XCTAssertTrue(
            element(app, "sidebar.empty").waitForExistence(timeout: Self.timeout), "Empty sidebar did not appear")
        attachScreenshot(app, named: "02-empty")
        try audit(app, verified: sidebarEmptyExemption)
    }

    /// F08 + F01.5 + F02.1: sample data talks to Local Echo; sending shows the status and the JSON body.
    @MainActor
    func testSampleRequestSendsToLocalEcho() throws {
        let app = launch()
        loadSampleDataFromOnboarding(app)
        openRequest(app, named: "Echo a GET")
        let send = element(app, "editor.send")
        XCTAssertTrue(send.waitForExistence(timeout: Self.timeout))
        attachScreenshot(app, named: "03-editor")
        try audit(app)
        send.tap()
        let status = element(app, "response.status")
        XCTAssertTrue(status.waitForExistence(timeout: Self.timeout), "No response status")
        XCTAssertTrue(status.label.contains("200"), "Unexpected status: \(status.label)")
        XCTAssertTrue(element(app, "response.body.tree").waitForExistence(timeout: Self.timeout), "JSON tree missing")
        attachScreenshot(app, named: "04-response")
        try audit(app)
    }

    /// F03.1 + F01.1 + X01.2: create a collection and a request, edit the URL and save.
    @MainActor
    func testCreateCollectionEditAndSaveRequest() throws {
        let app = launch()
        skipOnboarding(app)
        element(app, "sidebar.add").tap()
        menuItem(app, "New Collection").tap()
        let name = firstExisting([
            element(app, "prompt.name"), app.alerts.textFields.firstMatch, app.dialogs.textFields.firstMatch,
            app.sheets.textFields.firstMatch,
        ])
        XCTAssertTrue(name.exists, "Name prompt did not appear")
        name.tap()
        name.typeText("My API")
        // Wait for the typed text to reach the field before confirming (the alert can lag on iPad).
        expectation(for: NSPredicate(format: "value == %@", "My API"), evaluatedWith: name)
        waitForExpectations(timeout: Self.timeout)
        firstExisting([
            element(app, "prompt.ok"), app.alerts.buttons["OK"], app.dialogs.buttons["OK"], app.sheets.buttons["OK"],
        ]).tap()
        XCTAssertTrue(
            element(app, "sidebar.collection.My API").waitForExistence(timeout: Self.timeout), "Collection not created")

        element(app, "sidebar.add").tap()
        menuItem(app, "New Request").tap()
        let url = element(app, "editor.url")
        XCTAssertTrue(url.waitForExistence(timeout: Self.timeout), "Editor did not open")
        url.tap()
        selectAll(in: url, app: app)
        url.typeText("https://api.example.com/users?page=1")
        let save = element(app, "workspace.save")
        XCTAssertTrue(save.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(save.isEnabled, "Save should be enabled after editing")
        save.tap()
        let disabled = NSPredicate(format: "isEnabled == false")
        expectation(for: disabled, evaluatedWith: save)
        waitForExpectations(timeout: Self.timeout)
        tapTab(app, "params")
        attachScreenshot(app, named: "05-saved-request")
        try audit(app)
    }

    /// F04.1: switching the environment changes the resolved request (undefined-variable warning disappears).
    @MainActor
    func testEnvironmentSwitchResolvesVariables() throws {
        let app = launch()
        loadSampleDataFromOnboarding(app)
        openRequest(app, named: "Create JSON")
        let environment = element(app, "workspace.environment")
        XCTAssertTrue(environment.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(element(app, "editor.unresolved").exists, "Sample environment should resolve every variable")
        environment.tap()
        menuItem(app, "No Environment").tap()
        XCTAssertTrue(
            element(app, "editor.unresolved").waitForExistence(timeout: Self.timeout),
            "Missing-variable warning did not appear")
        environment.tap()
        menuItem(app, "Local").tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element(app, "editor.unresolved"))
        waitForExpectations(timeout: Self.timeout)
    }

    /// F06: sent requests appear in History, which passes the audit.
    @MainActor
    func testHistoryListsSentRequests() throws {
        let app = launch()
        loadSampleDataFromOnboarding(app)
        openRequest(app, named: "Echo a GET")
        element(app, "editor.send").tap()
        XCTAssertTrue(element(app, "response.status").waitForExistence(timeout: Self.timeout))
        goBackToSidebarIfNeeded(app)
        element(app, "sidebar.history").tap()
        XCTAssertTrue(element(app, "history.list").waitForExistence(timeout: Self.timeout), "History is empty")
        attachScreenshot(app, named: "06-history")
        try audit(app)
    }

    /// PRD §4: a Pro feature on the free plan explains itself instead of failing.
    @MainActor
    func testProFeatureShowsUpgradeSheet() throws {
        let app = launch()
        loadSampleDataFromOnboarding(app)
        openRequest(app, named: "Echo a GET")
        tapTab(app, "assert")
        let locked = element(app, "proLocked.assertionsAndRunner")
        XCTAssertTrue(locked.waitForExistence(timeout: Self.timeout))
        locked.tap()
        XCTAssertTrue(
            element(app, "pro.feature").waitForExistence(timeout: Self.timeout), "Upgrade sheet did not appear")
        attachScreenshot(app, named: "07-pro")
        try audit(app)
        element(app, "pro.close").tap()
    }

    /// X04.2: Erase All Data returns the app to first launch.
    @MainActor
    func testEraseAllDataReturnsToOnboarding() throws {
        let app = launch()
        loadSampleDataFromOnboarding(app)
        openSettings(app)
        XCTAssertTrue(
            element(app, "settings.appearance").waitForExistence(timeout: Self.timeout), "Settings did not open")
        attachScreenshot(app, named: "08-settings")
        try audit(app)
        let erase = element(app, "settings.erase")
        scrollUntilExists(erase, in: app)
        XCTAssertTrue(erase.exists, "Erase All Data not found")
        erase.tap()
        app.buttons["Erase All Data"].firstMatch.tap()
        XCTAssertTrue(
            element(app, "onboarding.skip").waitForExistence(timeout: Self.timeout),
            "Onboarding did not return after erase")
    }

    #if os(iOS)
        /// B8 / ADR-0038: every main screen at the largest accessibility text size, for visual review of clipping
        /// and truncation (screenshots are kept in the result bundle and summarized in SDLC_LOG).
        @MainActor
        func testLargestDynamicTypeSizes() throws {
            let app = XCUIApplication()
            app.launchArguments =
                Self.baseArguments + [
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                ]
            app.launch()
            let next = element(app, "onboarding.continue")
            XCTAssertTrue(next.waitForExistence(timeout: Self.timeout))
            attachScreenshot(app, named: "ax5-onboarding")
            loadSampleDataFromOnboarding(app)
            attachScreenshot(app, named: "ax5-sidebar")
            openRequest(app, named: "Create JSON")
            XCTAssertTrue(element(app, "editor.send").waitForExistence(timeout: Self.timeout))
            attachScreenshot(app, named: "ax5-editor")
            element(app, "editor.send").tap()
            XCTAssertTrue(element(app, "response.status").waitForExistence(timeout: Self.timeout))
            attachScreenshot(app, named: "ax5-response")
            goBackToSidebarIfNeeded(app)
            scrollUntilExists(element(app, "sidebar.history"), in: app)
            element(app, "sidebar.history").tap()
            XCTAssertTrue(element(app, "history.list").waitForExistence(timeout: Self.timeout))
            attachScreenshot(app, named: "ax5-history")
            goBackToSidebarIfNeeded(app)
            scrollUntilExists(element(app, "sidebar.settings"), in: app)
            element(app, "sidebar.settings").tap()
            XCTAssertTrue(element(app, "settings.appearance").waitForExistence(timeout: Self.timeout))
            attachScreenshot(app, named: "ax5-settings")
        }
    #endif

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = Self.baseArguments
            app.launch()
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(pro: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.baseArguments + (pro ? ["-UITestPro"] : [])
        app.launch()
        #if os(macOS)
            // On some hosts SwiftUI restores "no windows" for the bundle despite the flags above (ADR-0037);
            // open one the way a user would.
            if !app.windows.firstMatch.waitForExistence(timeout: 5) {
                app.menuBars.menuBarItems["File"].click()
                app.menuItems["New Window"].click()
            }
        #endif
        app.activate()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The first element that appears within the timeout (identifiers don't always reach alert fields).
    @MainActor
    private func firstExisting(_ candidates: [XCUIElement]) -> XCUIElement {
        let deadline = Date().addingTimeInterval(Self.timeout)
        while Date() < deadline {
            if let found = candidates.first(where: \.exists) { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return candidates[0]
    }

    /// Editor tabs scroll horizontally on narrow screens.
    @MainActor
    private func tapTab(_ app: XCUIApplication, _ name: String) {
        let tab = element(app, "editor.tab.\(name)")
        XCTAssertTrue(tab.waitForExistence(timeout: Self.timeout))
        #if os(iOS)
            let visible = app.windows.firstMatch.frame
            for _ in 0..<4 where !visible.contains(tab.frame) { element(app, "editor.tabs").swipeLeft() }
        #endif
        tab.tap()
    }

    /// Forms load rows lazily; scroll until `target` exists.
    @MainActor
    private func scrollUntilExists(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            #if os(iOS)
                app.swipeUp()
            #else
                app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
            #endif
        }
    }

    /// Menu entries are menu items on macOS and buttons on iOS.
    @MainActor
    private func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        #if os(macOS)
            app.menuItems[title].firstMatch
        #else
            app.buttons[title].firstMatch
        #endif
    }

    @MainActor
    private func skipOnboarding(_ app: XCUIApplication) {
        let skip = element(app, "onboarding.skip")
        XCTAssertTrue(skip.waitForExistence(timeout: Self.timeout))
        skip.tap()
    }

    @MainActor
    private func loadSampleDataFromOnboarding(_ app: XCUIApplication) {
        let next = element(app, "onboarding.continue")
        let loadSample = element(app, "onboarding.loadSample")
        XCTAssertTrue(next.waitForExistence(timeout: Self.timeout))
        for _ in 0..<6 where !loadSample.exists {
            if next.waitForExistence(timeout: 2) { next.tap() }
            _ = loadSample.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(loadSample.waitForExistence(timeout: Self.timeout), "Last onboarding page did not appear")
        loadSample.tap()
        XCTAssertTrue(
            element(app, "sidebar.collection.Sample").waitForExistence(timeout: Self.timeout),
            "Sample collection missing")
    }

    /// Finds a request with sidebar search (folders start collapsed).
    @MainActor
    private func openRequest(_ app: XCUIApplication, named name: String) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: Self.timeout))
        search.tap()
        search.typeText(name)
        let row = element(app, "sidebar.request.\(name)")
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout), "Request \(name) not found")
        row.tap()
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        #if os(macOS)
            app.typeKey(",", modifierFlags: .command)
        #else
            goBackToSidebarIfNeeded(app)
            element(app, "sidebar.settings").tap()
        #endif
    }

    /// On iPhone the split view collapses; return to the sidebar.
    @MainActor
    private func goBackToSidebarIfNeeded(_ app: XCUIApplication) {
        #if os(iOS)
            if !element(app, "sidebar.history").isHittable {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                if back.exists { back.tap() }
            }
            // Leave sidebar search so the full list (History, Settings) is shown again.
            // The dismiss button is "Cancel" or, with the floating search field, "close".
            let clear = app.buttons["Clear text"].firstMatch
            if clear.exists { clear.tap() }
            for label in ["Cancel", "close"] {
                let dismiss = app.buttons[label].firstMatch
                if dismiss.exists {
                    dismiss.tap()
                    break
                }
            }
        #endif
    }

    @MainActor
    private func selectAll(in field: XCUIElement, app: XCUIApplication) {
        #if os(macOS)
            field.typeKey("a", modifierFlags: .command)
        #else
            field.press(forDuration: 1.0)
            let selectAll = app.menuItems["Select All"].firstMatch
            if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        #endif
    }

    private var sidebarEmptyExemption: [AccessibilityAudit.VerifiedExemption] {
        #if os(iOS)
            [
                .init(
                    auditType: .textClipped, identifier: "sidebar.empty",
                    evidence: "SDLC_LOG Phase 1: wraps without clipping at accessibility-extra-extra-extra-large")
            ]
        #else
            []
        #endif
    }

    @MainActor
    private func audit(
        _ app: XCUIApplication, verified: [AccessibilityAudit.VerifiedExemption] = [], file: StaticString = #filePath,
        line: UInt = #line
    )
        throws
    {
        try AccessibilityAudit.run(on: app, verified: verified, file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
