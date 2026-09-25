import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI

/// Top-level navigation: sidebar (collections, history) and the request workspace (X01).
struct RootView: View {
    let app: AppModel
    @State private var workspace: WorkspaceModel
    @SceneStorage("workspace.selection") private var storedSelection: Data?
    @State private var isSettingsPresented = false
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    init(app: AppModel) {
        self.app = app
        _workspace = State(initialValue: WorkspaceModel(app: app))
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView(app: app, workspace: workspace, isSettingsPresented: $isSettingsPresented)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            DetailView(app: app, workspace: workspace)
        }
        // Side by side on iPad, rather than a sidebar overlay that dims the request being edited.
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.workspace, workspace)
        .task {
            await app.load()
            restoreSelection()
        }
        .onChange(of: workspace.selection) { _, selection in
            storedSelection = try? JSONEncoder().encode(selection)
        }
        .presentsPaywall(app, level: 0)
        .alert(
            "Welcome to RequestPad Pro",
            isPresented: Binding(get: { app.store.didUnlockPro }, set: { app.store.didUnlockPro = $0 })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All Pro features are unlocked on every device signed in with this Apple Account.")
        }
        .onChange(of: scenePhase) { _, phase in
            // Subscriptions can expire or renew while the app is in the background.
            if phase == .active { Task { await app.store.refreshEntitlements() } }
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack { SettingsView(app: app) }
        }
        #if os(iOS)
            .fullScreenCover(isPresented: onboardingBinding) { OnboardingView(app: app) }
        #else
            .sheet(isPresented: onboardingBinding) { OnboardingView(app: app).frame(width: 560, height: 520) }
        #endif
        .alert(item: $app.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
        .preferredColorScheme(app.appearance.colorScheme)
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { app.isLoaded && !app.onboardingCompleted }, set: { if !$0 { app.completeOnboarding() } })
    }

    private func restoreSelection() {
        guard workspace.selection == nil, let data = storedSelection,
            let selection = try? JSONDecoder().decode(WorkspaceSelection.self, from: data)
        else { return }
        if case .request(let reference) = selection, app.request(reference) == nil { return }
        if case .scratch = selection { return }
        workspace.selection = selection
    }
}

/// The detail column: editor + response, history, or an empty state.
struct DetailView: View {
    let app: AppModel
    let workspace: WorkspaceModel

    var body: some View {
        Group {
            switch workspace.selection {
            case .history:
                HistoryView(app: app, workspace: workspace)
            case .request, .scratch:
                if let editor = workspace.editor {
                    RequestWorkspaceView(editor: editor, workspace: workspace)
                        .id(editor.id)
                } else {
                    EmptyStateView(
                        "Request Not Found", message: "It may have been deleted or moved.",
                        systemImage: "questionmark.folder")
                }
            case nil:
                EmptyStateView(
                    "No Request Selected", message: "Select a request or create a new one.", systemImage: "paperplane"
                ) {
                    Button("New Request") { workspace.newRequest() }
                        .prominentButtonStyle()
                        .accessibilityIdentifier("detail.newRequest")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("root.detail.empty")
            }
        }
    }
}

extension WorkspaceModel {
    /// The collection of the current selection.
    var currentCollectionID: UUID? {
        if case .request(let reference) = selection { return reference.collectionID }
        return nil
    }

    /// ⌘N: a new request in the current collection (or the first one), else an unsaved scratch request.
    func newRequest() {
        let collectionID =
            currentCollectionID
            ?? app.collections.first(where: { $0.session != nil && $0.summary.storage != .sample })?.id
        guard let collectionID else {
            openScratch(RequestItem(name: String(localized: "New Request"), url: "https://"))
            return
        }
        let folderKey: String? = {
            if case .request(let reference) = selection { return app.request(reference)?.folderKey }
            return nil
        }()
        Task {
            if let reference = await app.createRequest(in: collectionID, folderKey: folderKey) {
                selection = .request(reference)
            }
        }
    }
}

extension Preferences.Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
