import XCTest

/// Runs `performAccessibilityAudit` and fails with the offending element's details.
///
/// Two macOS-only exemptions exist, both documented in `docs/DECISIONS.md` (ADR-0019):
/// 1. SwiftUI wraps each window's content, and each `NavigationSplitView` column, in an unlabeled `Group` with no
///    identifier, and AppKit owns the system Touch Bar element. The app cannot attach accessibility attributes to
///    these. Only those exact elements (containers matched by frame) are exempt, and only from the "sufficient
///    element description" audit.
/// 2. The sidebar column uses the system translucent material, so the contrast audit samples whatever windows are
///    behind it and gives machine-dependent results. Contrast issues inside the sidebar column are exempt on macOS
///    only; contrast is covered deterministically by the iOS/iPadOS audit and by the manual macOS Accessibility
///    Inspector pass in `docs/HUMAN_HANDOFF.md`.
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
        let layout = FrameworkLayout(app: app)
        try app.performAccessibilityAudit { issue in
            if layout.isExempt(issue) {
                return true
            }
            if let element = issue.element,
                verified.contains(where: { $0.auditType == issue.auditType && $0.identifier == element.identifier })
            {
                return true
            }
            XCTFail(
                "\(issue.compactDescription) — \(issue.detailedDescription) — element: "
                    + (issue.element?.debugDescription ?? "none"),
                file: file, line: line)
            return true
        }
    }
}

@MainActor
private struct FrameworkLayout {
    let containerFrames: [CGRect]
    let sidebarFrames: [CGRect]

    init(app: XCUIApplication) {
        #if os(macOS)
            let windowFrames = app.windows.allElementsBoundByIndex.map(\.frame)
            let columns = app.splitGroups.allElementsBoundByIndex.map { splitGroup in
                splitGroup.children(matching: .group).allElementsBoundByIndex.map(\.frame)
            }
            containerFrames = windowFrames + columns.flatMap { $0 }
            sidebarFrames = columns.compactMap(\.first)
        #else
            containerFrames = []
            sidebarFrames = []
        #endif
    }

    func isExempt(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        #if os(macOS)
            guard let element = issue.element else { return false }
            switch issue.auditType {
            case .sufficientElementDescription:
                // The system Touch Bar (present on some MacBook Pro models) is owned by AppKit.
                if element.elementType == .touchBar { return true }
                return element.elementType == .group && element.identifier.isEmpty && element.label.isEmpty
                    && containerFrames.contains(element.frame)
            case .contrast:
                return sidebarFrames.contains { $0.contains(element.frame) }
            default:
                return false
            }
        #else
            return false
        #endif
    }
}
