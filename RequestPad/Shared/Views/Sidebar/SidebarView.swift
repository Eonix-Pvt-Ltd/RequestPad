import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#endif

/// A name prompt shown in an alert (new collection, new folder, rename).
struct NamePrompt: Identifiable {
    enum Purpose {
        case newCollection
        case newFolderCollection
        case newFolder(collectionID: UUID, parentKey: String?)
        case renameCollection(UUID)
        case renameFolder(collectionID: UUID, key: String)
        case renameRequest(RequestReference)
    }

    let id = UUID()
    var purpose: Purpose
    var title: LocalizedStringKey
    var text: String
}

/// Sidebar: collections tree, search, history and actions (F03, P01, X01).
struct SidebarView: View {
    let app: AppModel
    @Bindable var workspace: WorkspaceModel
    @Binding var isSettingsPresented: Bool
    @State private var searchText = ""
    @State private var prompt: NamePrompt?
    @State private var folderPicker: FolderPickerPurpose?
    @State private var isImportPresented = false
    @State private var sheet: SidebarSheet?
    @State private var pendingDeletion: PendingDeletion?
    @State private var promptText = ""
    #if os(iOS)
        @FocusState private var isSearchFocused: Bool
    #endif

    var body: some View {
        List(selection: $workspace.selection) {
            if searchText.isEmpty {
                Section {
                    if app.collections.isEmpty && app.isLoaded {
                        Label("No Collections Yet", systemImage: "tray")
                            .foregroundStyle(Color.textSecondary)
                            .accessibilityIdentifier("sidebar.empty")
                    }
                    ForEach(app.collections) { state in
                        CollectionRow(app: app, state: state, actions: actions)
                    }
                    .onMove { source, destination in Task { await app.moveCollections(from: source, to: destination) } }
                }
            } else {
                Section {
                    let results = searchResults
                    if results.isEmpty {
                        Text("No matching requests").foregroundStyle(Color.textSecondary)
                    }
                    ForEach(results, id: \.reference) { result in
                        RequestRowLabel(request: result.request, detail: result.collectionName)
                            .tag(WorkspaceSelection.request(result.reference))
                    }
                } header: {
                    SectionHeader("Results")
                }
            }
            Section {
                Label("History", systemImage: "clock")
                    .tag(WorkspaceSelection.history)
                    .accessibilityIdentifier("sidebar.history")
                #if os(iOS)
                    // A row rather than a toolbar item: bar items move into an overflow menu at large text sizes.
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .accessibilityIdentifier("sidebar.settings")
                #endif
            }
        }
        .accessibilityIdentifier("sidebar.list")
        .searchable(text: $searchText, prompt: Text("Search requests"))
        #if os(iOS)
            .searchFocusedIfAvailable($isSearchFocused)
        #endif
        .onChange(of: workspace.requestedSheet) { _, requested in
            guard let requested else { return }
            sheet = requested
            workspace.requestedSheet = nil
        }
        #if os(iOS)
            // Choosing a search result hides the keyboard so the request isn't half covered (iPad). Resigning the
            // first responder no longer reaches the search field on iOS 27, so iOS 18+ clears its focus instead.
            .onChange(of: workspace.selection) { _, _ in
                guard !searchText.isEmpty else { return }
                isSearchFocused = false
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        #endif
        .navigationTitle("RequestPad")
        .toolbar { toolbar }
        .onChange(of: prompt?.id) { _, _ in promptText = prompt?.text ?? "" }
        .alert(prompt?.title ?? "", isPresented: promptBinding, presenting: prompt) { current in
            TextField("Name", text: $promptText)
                .accessibilityIdentifier("prompt.name")
            Button("Cancel", role: .cancel) {}
            // `current` is captured when the alert appears; the typed name lives in `promptText`.
            Button("OK") {
                var submitted = current
                submitted.text = promptText
                submit(submitted)
            }
            .accessibilityIdentifier("prompt.ok")
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "", isPresented: deletionBinding, titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button(deletion.confirmLabel, role: .destructive) { Task { await deletion.perform() } }
        } message: { deletion in
            Text(deletion.message)
        }
        .fileImporter(isPresented: folderPickerBinding, allowedContentTypes: [.folder]) { result in
            handleFolderPick(result)
        }
        .sheet(isPresented: $isImportPresented) {
            ImportView(app: app, workspace: workspace)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .collectionSettings(let id):
                CollectionSettingsView(app: app, collectionID: id)
            case .folderSettings(let id, let key):
                FolderSettingsView(app: app, collectionID: id, folderKey: key)
            case .environments(let id):
                EnvironmentsView(app: app, collectionID: id)
            case .runner(let id, let folderKey):
                RunnerView(app: app, collectionID: id, folderKey: folderKey)
            case .cookies:
                CookieJarView(app: app)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Request", systemImage: "square.and.pencil") { workspace.newRequest() }
                Button("New Collection", systemImage: "folder.badge.plus") {
                    guard app.require(app.gate.canCreateCollection(existingNonSampleCount: app.userCollections.count))
                    else { return }
                    prompt = NamePrompt(purpose: .newCollection, title: "New Collection", text: "")
                }
                Divider()
                Button("Open Collection Folder…", systemImage: "folder") {
                    if app.require(.folderCollections) { folderPicker = .openExisting }
                }
                Button("New Collection in Folder…", systemImage: "folder.badge.gearshape") {
                    if app.require(.folderCollections) {
                        prompt = NamePrompt(purpose: .newFolderCollection, title: "Collection Name", text: "")
                    }
                }
                Divider()
                Button("Import…", systemImage: "square.and.arrow.down") { isImportPresented = true }
                Button("Cookie Jar", systemImage: "birthday.cake") {
                    if app.require(.cookieJar) { sheet = .cookies }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("sidebar.add")
        }
    }

    // MARK: Search (F03.4)

    private struct SearchResult {
        var reference: RequestReference
        var request: RequestItem
        var collectionName: String
    }

    private var searchResults: [SearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return app.collections.flatMap { state in
            (state.tree?.requests ?? []).filter { entry in
                entry.request.name.lowercased().contains(query) || entry.request.url.lowercased().contains(query)
                    || entry.request.method.rawValue.lowercased() == query
            }.map {
                SearchResult(
                    reference: RequestReference(collectionID: state.id, key: $0.key), request: $0.request,
                    collectionName: state.summary.name)
            }
        }
    }

    // MARK: Actions

    private var actions: SidebarActions {
        SidebarActions(
            prompt: { prompt = $0 }, sheet: { sheet = $0 }, delete: { pendingDeletion = $0 },
            regrant: { id in folderPicker = .regrant(id) }, convert: { id in folderPicker = .convert(id) },
            select: { workspace.selection = $0 }, renamed: { workspace.followRename(to: $0) },
            selected: workspace.currentRequestReference)
    }

    private func submit(_ prompt: NamePrompt) {
        let name = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            switch prompt.purpose {
            case .newCollection:
                await app.createCollection(named: name)
            case .newFolderCollection:
                folderPicker = .createNew(name)
            case .newFolder(let collectionID, let parentKey):
                await app.createFolder(in: collectionID, parentKey: parentKey, name: name)
            case .renameCollection(let id):
                await app.renameCollection(id, to: name)
            case .renameFolder(let collectionID, let key):
                await app.renameFolder(in: collectionID, key: key, to: name)
            case .renameRequest(let reference):
                if let updated = await app.renameRequest(reference, to: name),
                    case .request(let current) = workspace.selection, current == reference
                {
                    workspace.followRename(to: updated)
                }
            }
        }
    }

    private func handleFolderPick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result, let purpose = folderPicker else { return }
        folderPicker = nil
        Task {
            switch purpose {
            case .openExisting: await app.openFolderCollection(at: url, createIfEmpty: nil)
            case .createNew(let name): await app.openFolderCollection(at: url, createIfEmpty: name)
            case .regrant(let id): await app.regrantAccess(id, url: url)
            case .convert(let id): await app.convertToFolder(id, destination: url)
            }
        }
    }

    private var promptBinding: Binding<Bool> { Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }) }
    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }
    private var folderPickerBinding: Binding<Bool> {
        Binding(get: { folderPicker != nil }, set: { if !$0 { folderPicker = nil } })
    }
}

enum FolderPickerPurpose {
    case openExisting
    case createNew(String)
    case regrant(UUID)
    case convert(UUID)
}

enum SidebarSheet: Identifiable, Equatable {
    case collectionSettings(UUID)
    case folderSettings(UUID, String)
    case environments(UUID)
    case runner(UUID, String?)
    case cookies

    var id: String {
        switch self {
        case .collectionSettings(let id): "settings-\(id)"
        case .folderSettings(let id, let key): "folder-\(id)-\(key)"
        case .environments(let id): "environments-\(id)"
        case .runner(let id, let key): "runner-\(id)-\(key ?? "")"
        case .cookies: "cookies"
        }
    }
}

/// A destructive action awaiting confirmation (F03.1).
struct PendingDeletion {
    var title: String
    var message: String
    var confirmLabel: String
    var perform: @MainActor () async -> Void
}

struct SidebarActions {
    var prompt: (NamePrompt) -> Void
    var sheet: (SidebarSheet) -> Void
    var delete: (PendingDeletion) -> Void
    var regrant: (UUID) -> Void
    var convert: (UUID) -> Void
    var select: (WorkspaceSelection) -> Void
    var renamed: (RequestReference) -> Void
    /// The selected request, so folders containing it expand (reveal the selection).
    var selected: RequestReference?
}

/// One collection with its folders and requests.
struct CollectionRow: View {
    let app: AppModel
    let state: CollectionState
    let actions: SidebarActions
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let problem = state.problem {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Text(problem.errorDescription ?? "").font(.callout)
                    if state.summary.storage == .folder {
                        Button("Grant Access…") { actions.regrant(state.id) }
                            .accessibilityIdentifier("sidebar.grantAccess")
                    }
                }
            } else if let tree = state.tree {
                FolderContents(app: app, tree: tree, folderKey: nil, actions: actions)
                ForEach(tree.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
                        Color.textSecondary)
                }
            } else {
                ProgressView().accessibilityLabel(Text("Loading collection"))
            }
        } label: {
            Label {
                Text(state.summary.name)
            } icon: {
                Image(systemName: Self.icon(for: state.summary.storage))
            }
            .contextMenu { menu }
            .accessibilityIdentifier("sidebar.collection.\(state.summary.name)")
        }
    }

    static func icon(for storage: CollectionStorage) -> String {
        switch storage {
        case .native: "tray.full"
        case .folder: "folder"
        case .sample: "sparkles"
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("New Request") {
            Task {
                if let reference = await app.createRequest(in: state.id, folderKey: nil) {
                    actions.select(.request(reference))
                }
            }
        }
        Button("New Folder") {
            actions.prompt(
                NamePrompt(purpose: .newFolder(collectionID: state.id, parentKey: nil), title: "New Folder", text: ""))
        }
        Divider()
        Button("Environments…") { actions.sheet(.environments(state.id)) }
        Button("Collection Settings…") { actions.sheet(.collectionSettings(state.id)) }
        Button("Run Collection…") { if app.require(.assertionsAndRunner) { actions.sheet(.runner(state.id, nil)) } }
        Divider()
        Button("Rename…") {
            actions.prompt(
                NamePrompt(purpose: .renameCollection(state.id), title: "Rename Collection", text: state.summary.name))
        }
        if state.summary.storage == .native {
            Button("Convert to Folder Collection…") { if app.require(.folderCollections) { actions.convert(state.id) } }
        }
        Button(state.summary.storage == .folder ? "Remove from RequestPad…" : "Delete Collection…", role: .destructive)
        {
            actions.delete(
                PendingDeletion(
                    title: String(localized: "Delete “\(state.summary.name)”?"),
                    message: state.summary.storage == .folder
                        ? String(localized: "The collection is removed from RequestPad. Its files stay in the folder.")
                        : String(localized: "All requests, folders and environments in this collection are deleted."),
                    confirmLabel: String(localized: "Delete"), perform: { await app.deleteCollection(state.id) }))
        }
    }
}

/// Folders and requests at one level; subfolders recurse.
struct FolderContents: View {
    let app: AppModel
    let tree: CollectionTree
    let folderKey: String?
    let actions: SidebarActions

    var body: some View {
        let children = tree.children(of: folderKey)
        ForEach(children.folders) { folder in
            FolderRow(app: app, tree: tree, folder: folder, actions: actions)
        }
        ForEach(children.requests) { entry in
            RequestRow(
                app: app, reference: RequestReference(collectionID: tree.id, key: entry.key), request: entry.request,
                actions: actions)
        }
        if children.folders.isEmpty && children.requests.isEmpty && folderKey == nil {
            Text("No requests yet").font(.callout).foregroundStyle(Color.textSecondary)
        }
    }
}

struct FolderRow: View {
    let app: AppModel
    let tree: CollectionTree
    let folder: CollectionTree.Folder
    let actions: SidebarActions
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            AnyView(FolderContents(app: app, tree: tree, folderKey: folder.key, actions: actions))
        } label: {
            Label(folder.name, systemImage: "folder")
                .contextMenu {
                    Button("New Request") {
                        Task {
                            if let reference = await app.createRequest(in: tree.id, folderKey: folder.key) {
                                actions.select(.request(reference))
                            }
                        }
                    }
                    Button("New Folder") {
                        actions.prompt(
                            NamePrompt(
                                purpose: .newFolder(collectionID: tree.id, parentKey: folder.key), title: "New Folder",
                                text: ""))
                    }
                    Button("Folder Settings…") { actions.sheet(.folderSettings(tree.id, folder.key)) }
                    Button("Run Folder…") {
                        if app.require(.assertionsAndRunner) { actions.sheet(.runner(tree.id, folder.key)) }
                    }
                    Divider()
                    Button("Rename…") {
                        actions.prompt(
                            NamePrompt(
                                purpose: .renameFolder(collectionID: tree.id, key: folder.key), title: "Rename Folder",
                                text: folder.name))
                    }
                    Button("Delete Folder…", role: .destructive) {
                        actions.delete(
                            PendingDeletion(
                                title: String(localized: "Delete “\(folder.name)”?"),
                                message: String(localized: "The folder and every request in it are deleted."),
                                confirmLabel: String(localized: "Delete"),
                                perform: { await app.deleteFolder(in: tree.id, key: folder.key) }))
                    }
                }
        }
        .onAppear(perform: revealSelection)
        .onChange(of: actions.selected) { _, _ in revealSelection() }
    }

    /// Expands when the selected request is inside this folder (at any depth).
    private func revealSelection() {
        guard let selected = actions.selected, selected.collectionID == tree.id,
            let entry = tree.requests.first(where: { $0.key == selected.key })
        else { return }
        var current = entry.folderKey
        var visited: Set<String> = []
        while let key = current, visited.insert(key).inserted {
            if key == folder.key {
                isExpanded = true
                return
            }
            current = tree.folders.first { $0.key == key }?.parentKey
        }
    }
}

struct RequestRow: View {
    let app: AppModel
    let reference: RequestReference
    let request: RequestItem
    let actions: SidebarActions

    var body: some View {
        RequestRowLabel(request: request, detail: nil)
            .tag(WorkspaceSelection.request(reference))
            .contextMenu {
                Button("Rename…") {
                    actions.prompt(
                        NamePrompt(purpose: .renameRequest(reference), title: "Rename Request", text: request.name))
                }
                Button("Duplicate") {
                    Task { if let copy = await app.duplicateRequest(reference) { actions.select(.request(copy)) } }
                }
                Button("Move Up") {
                    Task { if let moved = await app.nudgeRequest(reference, by: -1) { actions.renamed(moved) } }
                }
                Button("Move Down") {
                    Task { if let moved = await app.nudgeRequest(reference, by: 1) { actions.renamed(moved) } }
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    actions.delete(
                        PendingDeletion(
                            title: String(localized: "Delete “\(request.name)”?"),
                            message: String(localized: "This can't be undone."),
                            confirmLabel: String(localized: "Delete"), perform: { await app.deleteRequest(reference) }))
                }
            }
            .accessibilityAction(named: Text("Move Up")) { Task { _ = await app.nudgeRequest(reference, by: -1) } }
            .accessibilityAction(named: Text("Move Down")) { Task { _ = await app.nudgeRequest(reference, by: 1) } }
    }
}

struct RequestRowLabel: View {
    let request: RequestItem
    let detail: String?
    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @SwiftUI.Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        // Method above the name at accessibility text sizes, so the name keeps the full row width.
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: Spacing.small))
        layout {
            MethodBadge(request.method)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(request.name).lineLimit(2)
                if let detail {
                    Text(detail).font(.caption)
                        .foregroundStyle(
                            backgroundProminence == .increased
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.textSecondary))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.request.\(request.name)")
    }
}

#if os(iOS)
    extension View {
        /// Binds the search field's focus where SwiftUI supports it (iOS 18+); earlier versions keep the default.
        @ViewBuilder fileprivate func searchFocusedIfAvailable(_ isFocused: FocusState<Bool>.Binding) -> some View {
            if #available(iOS 18, *) {
                searchFocused(isFocused)
            } else {
                self
            }
        }
    }
#endif
