import XCTest

/// Runs `performAccessibilityAudit` and fails with the offending element's details.
///
/// Three macOS-only exemptions exist, documented in `docs/DECISIONS.md` (ADR-0019, ADR-0038, ADR-0047):
/// 1. SwiftUI wraps each window's and sheet's content, and each `NavigationSplitView` column, in an unlabeled
///    `Group` with no identifier, and AppKit owns the system Touch Bar element. The app cannot attach accessibility
///    attributes to these. Only those exact elements (containers matched by frame) are exempt, and only from the "sufficient
///    element description" audit.
/// 2. The sidebar column uses the system translucent material, so the contrast audit samples whatever windows are
///    behind it and gives machine-dependent results. Contrast issues inside the sidebar column are exempt on macOS
///    only; contrast is covered deterministically by the iOS/iPadOS audit and by the manual macOS Accessibility
///    Inspector pass in `docs/HUMAN_HANDOFF.md`.
/// 3. Toolbar menu buttons are opened with AXShowMenu rather than AXPress; the "action missing" audit is exempt
///    for menu buttons only.
/// On iOS, Dynamic Type and text-clipping findings are attached for review and verified visually by
/// `testLargestDynamicTypeSizes` (ADR-0038).
/// Individual tests may also pass `verified` exemptions: an audit type plus an element identifier that was checked
/// by hand (e.g. screenshot at the largest accessibility text size) and recorded in `docs/SDLC_LOG.md`.
/// Every other issue fails the test.
enum AccessibilityAudit {
    /// A manually verified audit false positive for one specific element.
    struct VerifiedExemption {
        let auditType: XCUIAccessibilityAuditType
        let identifier: String
        /// Where the manual verification is recorded.
        let evidence: String
    }

    @MainActor
    static func run(
        on app: XCUIApplication, verified: [VerifiedExemption] = [], file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Audit the app as a user sees it: frontmost, with its window active.
        app.activate()
        // Let sheet and navigation animations finish: contrast is sampled from the screen.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let layout = FrameworkLayout(app: app)
        var findings: [String] = []
        var deferred: [String] = []
        try app.performAccessibilityAudit { issue in
            if layout.isExempt(issue) {
                return true
            }
            if let element = issue.element,
                verified.contains(where: { $0.auditType == issue.auditType && $0.identifier == element.identifier })
            {
                return true
            }
            #if os(iOS)
                // Dynamic Type issues are verified visually by `testLargestDynamicTypeSizes` (ADR-0038); they are
                // recorded here for review instead of failing, because the audit also flags system bar buttons and
                // wrapping text it cannot size-test.
                if issue.auditType == .dynamicType || issue.auditType == .textClipped {
                    deferred.append(
                        "\(issue.compactDescription) — " + (issue.element.map { "'\($0.label)'" } ?? "none"))
                    return true
                }
            #endif
            findings.append(
                "[\(issue.auditType.rawValue)] \(issue.compactDescription) — element: "
                    + (issue.element.map { "\($0.elementType) '\($0.identifier)' '\($0.label)' \($0.frame)" } ?? "none")
            )
            return true
        }
        if !deferred.isEmpty {
            XCTContext.runActivity(named: "Dynamic Type findings for visual review") { activity in
                let attachment = XCTAttachment(string: deferred.joined(separator: "\n"))
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        // One failure listing every issue on the screen, so a run shows the whole picture.
        if !findings.isEmpty {
            XCTFail(
                "\(findings.count) accessibility issue(s):\n" + findings.joined(separator: "\n"), file: file, line: line
            )
        }
    }
}

@MainActor
private struct FrameworkLayout {
    let containerFrames: [CGRect]
    let sidebarFrames: [CGRect]
    let screenFrame: CGRect
    let navigationBarFrames: [CGRect]
    let scrollViewFrames: [CGRect]

    init(app: XCUIApplication) {
        #if os(macOS)
            // Sheets get the same unlabeled hosting group as windows (e.g. the onboarding sheet).
            let windowFrames =
                app.windows.allElementsBoundByIndex.map(\.frame) + app.sheets.allElementsBoundByIndex.map(\.frame)
            let columns = app.splitGroups.allElementsBoundByIndex.map { splitGroup in
                splitGroup.children(matching: .group).allElementsBoundByIndex.map(\.frame)
            }
            containerFrames = windowFrames + columns.flatMap { $0 }
            sidebarFrames = columns.compactMap(\.first)
            screenFrame = .infinite
            navigationBarFrames = []
            scrollViewFrames = []
        #else
            containerFrames = []
            // iPad: the sidebar column, shown beside the detail in regular width.
            let sidebar = app.collectionViews.containing(.any, identifier: "sidebar.history").firstMatch
            sidebarFrames = app.windows.firstMatch.frame.width > 700 && sidebar.exists ? [sidebar.frame] : []
            screenFrame = app.windows.firstMatch.frame
            navigationBarFrames = app.navigationBars.allElementsBoundByIndex.map(\.frame)
            scrollViewFrames = app.scrollViews.allElementsBoundByIndex.map(\.frame)
        #endif
    }

    func isExempt(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        #if os(iOS)
            // Pixel-based findings without an element come from the dimmed screen behind an iPad form sheet and from
            // rows clipped by the sheet; there is no element to fix or reach (ADR-0038).
            guard let element = issue.element else {
                return issue.auditType == .elementDetection || issue.auditType == .contrast
            }
            guard issue.auditType == .contrast else { return false }
            // Contrast is sampled from the screen: elements cut off by the screen edge, bar buttons drawn by the
            // system on Liquid Glass, and the iPad glass sidebar measure the backdrop rather than the app's colors
            // (ADR-0038).
            return !screenFrame.contains(element.frame)
                || navigationBarFrames.contains { $0.contains(element.frame) }
                || sidebarFrames.contains { $0.contains(element.frame) }
                // Scrolled fully or partly out of view (e.g. at the bottom edge of an iPad form sheet).
                || !element.isHittable
                || scrollViewFrames.contains { $0.intersects(element.frame) && !$0.contains(element.frame) }
        #else
            guard let element = issue.element else { return false }
            switch issue.auditType {
            case .sufficientElementDescription:
                // The system Touch Bar (present on some MacBook Pro models) is owned by AppKit.
                if element.elementType == .touchBar { return true }
                return element.elementType == .group && element.identifier.isEmpty && element.label.isEmpty
                    && containerFrames.contains(element.frame)
            case .contrast:
                return sidebarFrames.contains { $0.contains(element.frame) }
            case .action:
                // SwiftUI toolbar menus are AppKit menu buttons: they open with AXShowMenu (VoiceOver VO-Space),
                // not AXPress, which the audit looks for.
                return element.elementType == .menuButton
            default:
                return false
            }
        #endif
    }
}
