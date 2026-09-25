import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import StoreKit
import SwiftUI

/// Request editor and response side by side (regular width) or switchable (compact width) (F01, F02).
struct RequestWorkspaceView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case request, response
        var id: String { rawValue }
    }

    let editor: RequestEditorModel
    let workspace: WorkspaceModel
    @State private var pane: Pane = .request
    @SwiftUI.Environment(\.requestReview) private var requestReview
    #if os(iOS)
        @SwiftUI.Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                WorkspaceBanners(editor: editor)
                URLBar(editor: editor, workspace: workspace)
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
            Divider()
            content
        }
        .navigationTitle(editor.request.name)
        #if os(macOS)
            .navigationSubtitle(subtitle)
        #else
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { WorkspaceToolbar(editor: editor, workspace: workspace) }
        .focusedSceneValue(\.requestEditor, editor)
        .onChange(of: editor.isSending) { _, isSending in
            if isSending, isCompact { pane = .response }
        }
        .onChange(of: editor.isReviewPromptDue) { _, isDue in
            guard isDue else { return }
            editor.isReviewPromptDue = false
            requestReview()
        }
        .alert("Allow Local Network Access", isPresented: $editor.isLocalNetworkExplainerPresented) {
            Button("Continue") { editor.confirmLocalNetworkAndSend() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This request goes to a device on your local network. iOS will ask for permission; RequestPad only connects to the addresses you send requests to."
            )
        }
        .sheet(
            isPresented: Binding(
                get: { workspace.isEnvironmentPickerPresented }, set: { workspace.isEnvironmentPickerPresented = $0 })
        ) {
            if let collectionID = editor.reference?.collectionID {
                EnvironmentPickerSheet(app: editor.app, collectionID: collectionID)
            }
        }
    }

    private var subtitle: String {
        guard let reference = editor.reference, let state = editor.app.collection(reference.collectionID) else {
            return String(localized: "Unsaved request")
        }
        return state.summary.name
    }

    private var isCompact: Bool {
        #if os(iOS)
            horizontalSizeClass == .compact
        #else
            false
        #endif
    }

    @ViewBuilder private var content: some View {
        if isCompact {
            VStack(spacing: 0) {
                Picker("Pane", selection: $pane) {
                    Text("Request").tag(Pane.request)
                    Text("Response").tag(Pane.response)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.xSmall)
                .accessibilityIdentifier("workspace.pane")
                switch pane {
                case .request: RequestEditorTabs(editor: editor)
                case .response: ResponseView(editor: editor)
                }
            }
        } else {
            #if os(macOS)
                HSplitView {
                    RequestEditorTabs(editor: editor)
                        .frame(minWidth: 320, maxWidth: .infinity)
                    ResponseView(editor: editor)
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            #else
                HStack(spacing: 0) {
                    RequestEditorTabs(editor: editor)
                        .frame(maxWidth: .infinity)
                    Divider()
                    ResponseView(editor: editor)
                        .frame(maxWidth: .infinity)
                }
            #endif
        }
    }
}

/// Conflict, read-only, unsupported-script and cURL-import notices above the URL bar.
private struct WorkspaceBanners: View {
    let editor: RequestEditorModel

    var body: some View {
        if editor.conflict != nil {
            NoticeBanner(
                systemImage: "exclamationmark.triangle.fill",
                message: Text("This request changed on disk since you opened it."), tint: .textOrange
            ) {
                Button("Use File") { Task { await editor.discardForFileVersion() } }
                    .accessibilityIdentifier("conflict.useFile")
                Button("Overwrite") { Task { await editor.save(overwrite: true) } }
                    .accessibilityIdentifier("conflict.overwrite")
            }
            .buttonStyle(.bordered)
        }
        if editor.isReadOnly {
            NoticeBanner(
                systemImage: "lock.fill",
                message: Text("This collection is read-only on the free plan. You can still send its requests."),
                tint: .textSecondary
            ) {
                Button("Upgrade") { editor.app.requestedProFeature = .unlimitedCollections }
                    .buttonStyle(.bordered)
            }
        }
        if editor.request.hasUnsupportedScripts {
            NoticeBanner(
                systemImage: "curlybraces",
                message: Text("This request has scripts. RequestPad keeps them in the file but doesn't run them."),
                tint: .textBlue)
        }
        if !editor.importNotices.isEmpty {
            NoticeBanner(
                systemImage: "info.circle",
                message: Text("Imported from cURL. \(editor.importNotices.joined(separator: " "))"), tint: .textBlue
            ) {
                Button("Dismiss") { editor.dismissImportNotices() }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// Save, environment and more actions.
private struct WorkspaceToolbar: ToolbarContent {
    let editor: RequestEditorModel
    let workspace: WorkspaceModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let collectionID = editor.reference?.collectionID {
                EnvironmentMenu(app: editor.app, collectionID: collectionID)
            }
            if editor.reference != nil {
                Button {
                    Task { await editor.save() }
                } label: {
                    Label(
                        "Save",
                        systemImage: editor.hasUnsavedChanges ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                }
                .disabled(!editor.hasUnsavedChanges || editor.isReadOnly)
                .accessibilityIdentifier("workspace.save")
            } else {
                SaveToCollectionMenu(editor: editor, workspace: workspace)
            }
            Menu {
                Button {
                    if let resolved = try? editor.previewResolved() { Clipboard.copy(CurlExporter.export(resolved)) }
                } label: {
                    Label("Copy as cURL", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("workspace.copyCurl")
                Button {
                    Task { await editor.revert() }
                } label: {
                    Label("Revert Changes", systemImage: "arrow.uturn.backward")
                }
                .disabled(!editor.hasUnsavedChanges)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("workspace.more")
        }
    }
}

/// Saves an unsaved (scratch) request into a collection.
private struct SaveToCollectionMenu: View {
    let editor: RequestEditorModel
    let workspace: WorkspaceModel

    var body: some View {
        let targets = editor.app.userCollections.filter { $0.session != nil && !editor.app.isReadOnly($0.id) }
        Menu {
            ForEach(targets) { state in
                Button(state.summary.name) {
                    Task {
                        if let reference = await editor.app.createRequest(
                            in: state.id, folderKey: nil, request: editor.request)
                        {
                            workspace.selection = .request(reference)
                        }
                    }
                }
            }
            if targets.isEmpty {
                Text("Create a collection first")
            }
        } label: {
            Label("Save to Collection", systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("workspace.saveToCollection")
    }
}

/// Picks the active environment of a collection (F04.1).
struct EnvironmentMenu: View {
    let app: AppModel
    let collectionID: UUID

    var body: some View {
        let environments = app.environments(for: collectionID)
        let active = app.activeEnvironment(for: collectionID)
        Menu {
            Picker(
                "Environment",
                selection: Binding(get: { active?.key }, set: { app.setActiveEnvironment($0, for: collectionID) })
            ) {
                Text("No Environment").tag(String?.none)
                ForEach(environments) { entry in
                    Text(entry.environment.name).tag(Optional(entry.key))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(active?.environment.name ?? String(localized: "No Environment"), systemImage: "globe")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(Text("Environment: \(active?.environment.name ?? String(localized: "None"))"))
        .accessibilityIdentifier("workspace.environment")
    }
}

/// ⌘E: a keyboard-friendly list of environments.
private struct EnvironmentPickerSheet: View {
    let app: AppModel
    let collectionID: UUID
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    app.setActiveEnvironment(nil, for: collectionID)
                    dismiss()
                } label: {
                    row(
                        name: String(localized: "No Environment"),
                        isActive: app.activeEnvironment(for: collectionID) == nil)
                }
                ForEach(app.environments(for: collectionID)) { entry in
                    Button {
                        app.setActiveEnvironment(entry.key, for: collectionID)
                        dismiss()
                    } label: {
                        row(
                            name: entry.environment.name,
                            isActive: app.activeEnvironment(for: collectionID)?.key == entry.key)
                    }
                }
            }
            .navigationTitle("Choose Environment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .frame(minWidth: 320, minHeight: 280)
    }

    private func row(name: String, isActive: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            if isActive {
                Image(systemName: "checkmark").accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
