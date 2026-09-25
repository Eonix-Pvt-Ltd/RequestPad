import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI

/// Headers, auth, variables and docs inherited by the requests of a collection or folder (F03.3).
private struct InheritedSettingsForm: View {
    let app: AppModel
    @Binding var settings: FolderSettings
    let inheritLabel: LocalizedStringKey
    let isReadOnly: Bool

    var body: some View {
        Section {
            KeyValueEditor(rows: $settings.headers, isReadOnly: isReadOnly, identifier: "settings.headers")
        } header: {
            SectionHeader("Headers")
        }
        Section {
            AuthEditor(app: app, auth: $settings.auth, inheritLabel: inheritLabel, isReadOnly: isReadOnly)
        } header: {
            SectionHeader("Authorization")
        }
        Section {
            KeyValueEditor(rows: $settings.variables, isReadOnly: isReadOnly, identifier: "settings.variables")
        } header: {
            SectionHeader("Variables")
        }
        Section {
            CodeEditor(
                text: $settings.docs, label: "Documentation", identifier: "settings.docs", isReadOnly: isReadOnly)
        } header: {
            SectionHeader("Documentation")
        }
    }
}

struct CollectionSettingsView: View {
    let app: AppModel
    let collectionID: UUID
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var settings = FolderSettings()
    @State private var useCookieJar = true

    var body: some View {
        let state = app.collection(collectionID)
        let isReadOnly = app.isReadOnly(collectionID)
        NavigationStack {
            Form {
                if let state {
                    Section {
                        LabeledContent("Type", value: storageName(state.summary.storage))
                        if let problem = state.problem {
                            Text(problem.errorDescription ?? "").foregroundStyle(Color.textOrange)
                        }
                    } header: {
                        SectionHeader("Storage")
                    }
                    Section {
                        Toggle("Use Cookie Jar", isOn: $useCookieJar)
                            .disabled(!app.gate.isPro)
                            .accessibilityIdentifier("collectionSettings.cookieJar")
                    } footer: {
                        Group {
                            Text(
                                app.gate.isPro
                                    ? "Store cookies from responses and send them with later requests."
                                    : "The cookie jar is part of RequestPad Pro.")
                        }
                        .foregroundStyle(Color.textSecondary)
                    }
                }
                InheritedSettingsForm(
                    app: app, settings: $settings, inheritLabel: "No inherited auth", isReadOnly: isReadOnly)
            }
            .formStyle(.grouped)
            .navigationTitle(state?.summary.name ?? String(localized: "Collection Settings"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if !isReadOnly { await app.saveCollectionSettings(settings, for: collectionID) }
                            if useCookieJar != state?.summary.useCookieJar {
                                await app.setCookieJar(useCookieJar, for: collectionID)
                            }
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("collectionSettings.save")
                }
            }
            .onAppear {
                settings = state?.tree?.settings ?? FolderSettings()
                useCookieJar = state?.summary.useCookieJar ?? true
            }
        }
        .sheetFrame(minWidth: 520, minHeight: 560)
        .presentsPaywall(app, level: 1)
    }

    private func storageName(_ storage: CollectionStorage) -> String {
        switch storage {
        case .native: String(localized: "On this device")
        case .folder: String(localized: "Folder (.bru files)")
        case .sample: String(localized: "Sample")
        }
    }
}

struct FolderSettingsView: View {
    let app: AppModel
    let collectionID: UUID
    let folderKey: String
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var settings = FolderSettings()

    var body: some View {
        let folder = app.collection(collectionID)?.tree?.folders.first { $0.key == folderKey }
        let isReadOnly = app.isReadOnly(collectionID)
        NavigationStack {
            Form {
                InheritedSettingsForm(
                    app: app, settings: $settings, inheritLabel: "Inherit from parent", isReadOnly: isReadOnly)
            }
            .formStyle(.grouped)
            .navigationTitle(folder?.name ?? String(localized: "Folder Settings"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await app.saveFolderSettings(settings, in: collectionID, key: folderKey)
                            dismiss()
                        }
                    }
                    .disabled(isReadOnly)
                    .accessibilityIdentifier("folderSettings.save")
                }
            }
            .onAppear { settings = folder?.settings ?? FolderSettings() }
        }
        .sheetFrame(minWidth: 520, minHeight: 560)
        .presentsPaywall(app, level: 1)
    }
}
