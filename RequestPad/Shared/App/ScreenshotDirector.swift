#if DEBUG
    import Foundation
    import RPCore
    import RPData
    import RPServices
    import RPStore

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// App Store screenshot scenes (Debug builds, UI-test mode only): `-ScreenshotScenario <name>`. Each scene is set
    /// up through the app's normal flows — sample data, a real send to Local Echo, a real runner run — so screenshots
    /// show the real UI (Guideline 2.3). Driven by `scripts/screenshots.sh`.
    enum ScreenshotScenario: String, CaseIterable {
        case response, chaining, graphql, runner, environments
        /// The paywall for the in-app purchase review screenshots (App Store Connect, not the product page).
        /// Launched without `-UITestPro`, so the store shows the products and prices of the StoreKit configuration.
        case paywall

        static var current: ScreenshotScenario? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-ScreenshotScenario"), index + 1 < arguments.count else {
                return nil
            }
            return ScreenshotScenario(rawValue: arguments[index + 1])
        }
    }

    @MainActor
    enum ScreenshotDirector {
        /// Window frame for Mac screenshots: 1440×900 points = 2880×1800 pixels on a Retina display, 60 points
        /// below the top of the screen (`scripts/screenshots.sh` captures exactly this rectangle).
        static let macWindowSize = CGSize(width: 1440, height: 900)
        static let macWindowTopInset: CGFloat = 60
        static let macWindowLeft: CGFloat = 100

        static func stage(_ scenario: ScreenshotScenario, app: AppModel, workspace: WorkspaceModel) async {
            app.appearance = .light
            if app.collection(SampleData.collectionID) == nil { await app.loadSampleData() }
            #if os(macOS)
                placeWindow()
            #endif
            switch scenario {
            case .response:
                await open("Create JSON", app: app, workspace: workspace, tab: "body")?.send()
            case .chaining:
                let editor = await open("1. Get a token", app: app, workspace: workspace, tab: "extract")
                // iPhone shows one pane: keep the extraction rules in view instead of switching to the response.
                if !isPhone { editor?.send() }
            case .graphql:
                let editor = await open("GraphQL query", app: app, workspace: workspace, tab: "body")
                await editor?.fetchSchema()
                // As with chaining: iPhone keeps the query and its completions in view.
                if !isPhone { editor?.send() }
            case .runner:
                _ = await open("Echo a GET", app: app, workspace: workspace, tab: "params")
                app.runnerAutoStart = true
                workspace.requestedSheet = .runner(SampleData.collectionID, nil)
            case .environments:
                _ = await open("Create JSON", app: app, workspace: workspace, tab: "body")
                workspace.requestedSheet = .environments(SampleData.collectionID)
            case .paywall:
                _ = await open("Echo a GET", app: app, workspace: workspace, tab: "params")
                app.requestedProFeature = .unlimitedCollections
            }
        }

        private static var isPhone: Bool {
            #if os(iOS)
                UIDevice.current.userInterfaceIdiom == .phone
            #else
                false
            #endif
        }

        private static func open(_ name: String, app: AppModel, workspace: WorkspaceModel, tab: String)
            async -> RequestEditorModel?
        {
            guard
                let saved = app.savedRequests().first(where: {
                    $0.reference.collectionID == SampleData.collectionID && $0.request.name == name
                })
            else { return nil }
            workspace.selection = .request(saved.reference)
            for _ in 0..<100 where workspace.editor == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            workspace.editor?.requestedTab = tab
            // Let the editor appear (on iPhone it is pushed) before acting on it, as a person would.
            try? await Task.sleep(for: .milliseconds(1200))
            return workspace.editor
        }

        #if os(macOS)
            private static func placeWindow() {
                guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                    let screen = window.screen ?? NSScreen.main
                else { return }
                let top = screen.frame.maxY - macWindowTopInset
                window.setFrame(
                    NSRect(
                        x: screen.frame.minX + macWindowLeft, y: top - macWindowSize.height, width: macWindowSize.width,
                        height: macWindowSize.height), display: true)
            }
        #endif
    }
#endif
