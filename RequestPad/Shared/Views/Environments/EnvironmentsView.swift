import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

/// A collection's environments and the global variables (F04).
struct EnvironmentsView: View {
    let app: AppModel
    let collectionID: UUID
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var path: [EnvironmentTarget] = []
    @State private var pendingDeletion: CollectionTree.EnvironmentEntry?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(app.environments(for: collectionID)) { entry in
                        NavigationLink(value: EnvironmentTarget.collection(key: entry.key)) {
                            HStack {
                                Text(entry.environment.name)
                                Spacer()
                                if app.activeEnvironment(for: collectionID)?.key == entry.key {
                                    Text("Active").font(.caption).foregroundStyle(Color.textSecondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Make Active") { app.setActiveEnvironment(entry.key, for: collectionID) }
                            Button("Delete", role: .destructive) { pendingDeletion = entry }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDeletion = entry }
                        }
                    }
                    Button {
                        path.append(.new)
                    } label: {
                        Label("Add Environment", systemImage: "plus")
                    }
                    .accessibilityIdentifier("environments.add")
                } header: {
                    Group {
                        Text("Environments")
                    }
                    .foregroundStyle(Color.textSecondary)
                } footer: {
                    Text("Secrets stay in the Keychain on this device, never in collection files.")
                        .foregroundStyle(Color.textSecondary)
                        // Kept short: macOS shows list section footers on a single line.
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    NavigationLink(value: EnvironmentTarget.globals) {
                        Label("Globals", systemImage: "globe")
                    }
                    .accessibilityIdentifier("environments.globals")
                } header: {
                    SectionHeader("Shared by All Collections")
                }
            }
            .navigationTitle("Environments")
            .navigationDestination(for: EnvironmentTarget.self) { target in
                EnvironmentEditor(app: app, collectionID: collectionID, target: target) { path.removeLast() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Delete “\(pendingDeletion?.environment.name ?? "")”?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Environment", role: .destructive) {
                    if let entry = pendingDeletion {
                        Task { await app.deleteEnvironment(key: entry.key, in: collectionID) }
                    }
                }
            } message: {
                Text("Its secret values are removed from the Keychain.")
            }
        }
        .sheetFrame(minWidth: 520, minHeight: 520)
    }
}

enum EnvironmentTarget: Hashable {
    case new
    case collection(key: String)
    case globals
}

/// One editable variable row; secrets keep their Keychain reference and a new value only if typed.
private struct VariableRow: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isEnabled: Bool
    var isSecret: Bool
    var plainValue: String
    var existingSecret: SecretRef?
    var newSecretValue: String?
}

/// Edits the variables of an environment or the globals (F04.1, F04.4, F04.5).
private struct EnvironmentEditor: View {
    let app: AppModel
    let collectionID: UUID
    let target: EnvironmentTarget
    let close: () -> Void
    @State private var name = ""
    @State private var rows: [VariableRow] = []
    @State private var original = RPCore.Environment(name: "")
    @State private var revealed: [UUID: String] = [:]
    @State private var isSaving = false

    var body: some View {
        Form {
            if target != .globals {
                Section {
                    TextField("Environment name", text: $name)
                        .accessibilityIdentifier("environment.name")
                } header: {
                    SectionHeader("Name")
                }
            }
            Section {
                ForEach($rows) { $row in
                    rowView($row)
                }
                .onDelete { rows.remove(atOffsets: $0) }
                Button {
                    rows.append(VariableRow(name: "", isEnabled: true, isSecret: false, plainValue: ""))
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
                .accessibilityIdentifier("environment.addVariable")
            } header: {
                Group {
                    Text("Variables")
                }
                .foregroundStyle(Color.textSecondary)
            } footer: {
                Group {
                    if let invalid = rows.first(where: { !$0.name.isEmpty && !Variable.isValidName($0.name) }) {
                        Text("“\(invalid.name)” isn't a valid name. Use letters, digits, “_”, “-” or “.”.")
                            .foregroundStyle(Color.textOrange)
                    } else {
                        Text("Use variables as {{name}} in URLs, headers, bodies and auth.")
                    }
                }
                .foregroundStyle(Color.textSecondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(
            target == .globals
                ? String(localized: "Globals") : (name.isEmpty ? String(localized: "New Environment") : name)
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid || isSaving)
                    .accessibilityIdentifier("environment.save")
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private func rowView(_ row: Binding<VariableRow>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Toggle(isOn: row.isEnabled) { Text("\(row.wrappedValue.name) enabled") }
                    .labelsHidden()
                    .toggleStyle(.checkboxCompat)
                TextField("Name", text: row.name)
                    .monospacedField()
                    .accessibilityIdentifier("environment.variable.name")
                Toggle("Secret", isOn: secretBinding(row))
                    .toggleStyle(.checkboxCompat)
                    .fixedSize()
                    .accessibilityIdentifier("environment.variable.secret")
            }
            if row.wrappedValue.isSecret {
                secretField(row)
            } else {
                TextField("Value", text: row.plainValue, axis: .vertical)
                    .monospacedField()
                    .accessibilityIdentifier("environment.variable.value")
            }
        }
    }

    @ViewBuilder private func secretField(_ row: Binding<VariableRow>) -> some View {
        let current = row.wrappedValue
        HStack {
            if let newValue = current.newSecretValue {
                SecureField(
                    "Secret value", text: Binding(get: { newValue }, set: { row.wrappedValue.newSecretValue = $0 })
                )
                .monospacedField()
                .accessibilityIdentifier("environment.variable.secretValue")
            } else if let value = revealed[current.id] {
                Text(verbatim: value).font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Hide") { revealed[current.id] = nil }
            } else {
                Text(verbatim: "••••••••").foregroundStyle(Color.textSecondary)
                    .accessibilityLabel(Text("Hidden secret"))
                Spacer()
                if let reference = current.existingSecret {
                    Button("Reveal") {
                        Task { if let value = await app.revealSecret(reference) { revealed[current.id] = value } }
                    }
                    .accessibilityIdentifier("environment.variable.reveal")
                }
                Button("Change") { row.wrappedValue.newSecretValue = "" }
            }
        }
        .buttonStyle(.borderless)
    }

    /// Making a value secret moves it into the Keychain on save; making a secret plain starts empty (it isn't read back).
    private func secretBinding(_ row: Binding<VariableRow>) -> Binding<Bool> {
        Binding(
            get: { row.wrappedValue.isSecret },
            set: { isSecret in
                row.wrappedValue.isSecret = isSecret
                if isSecret {
                    if row.wrappedValue.existingSecret == nil {
                        row.wrappedValue.newSecretValue = row.wrappedValue.plainValue
                    }
                    row.wrappedValue.plainValue = ""
                } else {
                    row.wrappedValue.newSecretValue = nil
                }
            })
    }

    private var isValid: Bool {
        (target == .globals || !name.trimmingCharacters(in: .whitespaces).isEmpty)
            && rows.allSatisfy { $0.name.isEmpty || Variable.isValidName($0.name) }
    }

    private func load() {
        let environment: RPCore.Environment
        switch target {
        case .new: environment = RPCore.Environment(name: "")
        case .collection(let key):
            environment =
                app.environments(for: collectionID).first { $0.key == key }?.environment ?? RPCore.Environment(name: "")
        case .globals: environment = app.globals
        }
        original = environment
        name = environment.name
        rows = environment.variables.map { variable in
            switch variable.value {
            case .plain(let value):
                VariableRow(
                    id: variable.id, name: variable.name, isEnabled: variable.isEnabled, isSecret: false,
                    plainValue: value)
            case .secret(let reference):
                VariableRow(
                    id: variable.id, name: variable.name, isEnabled: variable.isEnabled, isSecret: true, plainValue: "",
                    existingSecret: reference)
            }
        }
    }

    private func save() {
        isSaving = true
        var environment = original
        environment.name = name.trimmingCharacters(in: .whitespaces)
        var secretValues: [String: String] = [:]
        environment.variables = rows.filter { !$0.name.isEmpty }.map { row in
            if row.isSecret {
                if let value = row.newSecretValue { secretValues[row.name] = value }
                let reference =
                    row.existingSecret ?? SecretRef.environmentVariable(environmentKey: "new", name: row.name)
                return Variable(id: row.id, name: row.name, value: .secret(reference), isEnabled: row.isEnabled)
            }
            return Variable(id: row.id, name: row.name, value: .plain(row.plainValue), isEnabled: row.isEnabled)
        }
        let kept = Set(
            environment.variables.compactMap { variable -> SecretRef? in
                if case .secret(let reference) = variable.value { return reference }
                return nil
            })
        let removed = original.variables.compactMap { variable -> SecretRef? in
            if case .secret(let reference) = variable.value, !kept.contains(reference) { return reference }
            return nil
        }
        Task {
            defer { isSaving = false }
            switch target {
            case .globals:
                await app.saveGlobals(environment, secretValues: secretValues)
            case .new:
                guard
                    await app.saveEnvironment(environment, key: nil, in: collectionID, secretValues: secretValues)
                        != nil
                else { return }
            case .collection(let key):
                guard
                    await app.saveEnvironment(environment, key: key, in: collectionID, secretValues: secretValues)
                        != nil
                else { return }
            }
            for reference in removed { try? await app.environment.secrets.deleteSecret(for: reference) }
            close()
        }
    }
}
