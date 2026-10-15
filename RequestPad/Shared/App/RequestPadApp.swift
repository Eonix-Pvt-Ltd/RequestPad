import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

@main
struct RequestPadApp: App {
    static let mainWindowID = "main"
    @State private var launch = AppRuntime.shared.launch
    #if os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            LaunchRootView(launch: launch)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            RequestCommands()
            #if os(macOS)
                CommandGroup(replacing: .help) {
                    Link(String(localized: "RequestPad Support"), destination: AppLinks.support)
                    Link(String(localized: "Privacy Policy"), destination: AppLinks.privacy)
                }
            #endif
        }
        #if os(macOS)
            // Menu bar Quick Send (P09): off by default.
            MenuBarExtra(isInserted: menuBarBinding) {
                if let app = launch.appModel {
                    QuickSendView(app: app)
                        .preferredColorScheme(app.appearance.colorScheme)
                }
            } label: {
                Label("RequestPad Quick Send", systemImage: "paperplane.fill")
            }
            .menuBarExtraStyle(.window)
            Settings {
                if let app = launch.appModel {
                    SettingsView(app: app)
                        .frame(minWidth: 520, minHeight: 560)
                        .preferredColorScheme(app.appearance.colorScheme)
                }
            }
        #endif
    }
}

#if os(macOS)
    extension RequestPadApp {
        /// Shown while enabled in Settings; removing the item from the menu bar turns it off.
        fileprivate var menuBarBinding: Binding<Bool> {
            Binding(
                get: { launch.appModel.map { $0.menuBarQuickSendEnabled } ?? false },
                set: { launch.appModel?.menuBarQuickSendEnabled = $0 })
        }
    }
#endif

/// Shows the app once launch preparation succeeded, or a recoverable error.
struct LaunchRootView: View {
    let launch: LaunchModel

    var body: some View {
        switch launch.state {
        case .ready(let app):
            RootView(app: app)
        case .failed(let error):
            EmptyStateView(
                "RequestPad Couldn't Start", message: "\(error.title)\n\(error.message)",
                systemImage: "exclamationmark.triangle"
            ) {
                Button("Try Again") { launch.retry() }
                    .prominentButtonStyle()
                    .accessibilityIdentifier("root.retry")
            }
        }
    }
}

/// Keyboard shortcuts (X01.1, X01.3) acting on the focused window's editor.
struct RequestCommands: Commands {
    @FocusedValue(\.requestEditor) private var editor
    @FocusedValue(\.workspace) private var workspace
    @SwiftUI.Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // ⌘N creates a request (the app's primary "new" action); New Window moves to ⌥⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Request") { workspace?.newRequest() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspace == nil)
            #if os(macOS)
                Button("New Window") { openWindow(id: RequestPadApp.mainWindowID) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            #endif
            Button("Save Request") { Task { await editor?.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editor?.reference == nil || editor?.hasUnsavedChanges != true)
        }
        CommandMenu("Request") {
            Button("Send") { editor?.send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editor == nil || editor?.isSending == true)
            Button("Cancel") { editor?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(editor?.isSending != true)
            Divider()
            Button("Choose Environment…") { workspace?.isEnvironmentPickerPresented = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(workspace?.currentCollectionID == nil)
            Button("Focus URL") { workspace?.focusURLRequest = UUID() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(editor == nil)
        }
    }
}

struct RequestEditorFocusKey: FocusedValueKey {
    typealias Value = RequestEditorModel
}

struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

extension FocusedValues {
    var requestEditor: RequestEditorModel? {
        get { self[RequestEditorFocusKey.self] }
        set { self[RequestEditorFocusKey.self] = newValue }
    }

    var workspace: WorkspaceModel? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

enum AppLinks {
    static let support = RPCore.AppConstants.supportURL
    static let privacy = RPCore.AppConstants.privacyPolicyURL
    static let terms = RPCore.AppConstants.termsOfUseURL
}
