import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

/// App settings, data control, support and legal (X02, X04).
struct SettingsView: View {
    let app: AppModel
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.requestReview) private var requestReview
    @State private var timeoutSeconds = 30
    @State private var followRedirects = true
    @State private var isEchoRunning = false
    @State private var isEraseConfirmationPresented = false
    @State private var exportDocument: AppDataDocument?
    @State private var isImportPickerPresented = false
    @State private var diagnostics: String?
    @State private var isWorking = false
    @State private var isPaywallPresented = false
    #if os(macOS)
        @State private var loginItem = LoginItemModel()
    #endif
    @State private var restoreResult: EntitlementManager.RestoreResult?
    #if os(iOS)
        @State private var isRedeemingCode = false
    #endif

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("Theme", selection: $app.appearance) {
                    Text("System").tag(Preferences.Appearance.system)
                    Text("Light").tag(Preferences.Appearance.light)
                    Text("Dark").tag(Preferences.Appearance.dark)
                }
                .accessibilityIdentifier("settings.appearance")
            } header: {
                SectionHeader("Appearance")
            }
            Section {
                Stepper(value: $timeoutSeconds, in: 1...600, step: 5) {
                    Text("Default Timeout: \(timeoutSeconds) s")
                }
                .onChange(of: timeoutSeconds) { _, newValue in app.preferences.defaultTimeoutSeconds = newValue }
                .accessibilityIdentifier("settings.timeout")
                Toggle("Follow Redirects for New Requests", isOn: $followRedirects)
                    .onChange(of: followRedirects) { _, newValue in app.preferences.followRedirects = newValue }
                    .accessibilityIdentifier("settings.followRedirects")
                LabeledContent(
                    "History",
                    value: app.gate.isPro
                        ? String(localized: "Last 1,000 requests") : String(localized: "Last 100 requests (Pro: 1,000)")
                )
            } header: {
                Group {
                    Text("Requests")
                }
                .foregroundStyle(Color.textSecondary)
            } footer: {
                Group {
                    Text("Used when a request doesn't set its own timeout.")
                }
                .foregroundStyle(Color.textSecondary)
            }
            #if os(macOS)
                macSection
            #endif
            echoSection
            Section {
                LabeledContent("Status", value: PaywallCopy.statusLine(for: app.store.source))
                    .accessibilityIdentifier("settings.proStatus")
                if !app.store.source.isPro {
                    Button("See Pro Features") { isPaywallPresented = true }
                        .accessibilityIdentifier("settings.pro")
                }
                Button(app.store.isRestoring ? "Restoring…" : "Restore Purchases") {
                    Task { restoreResult = await app.store.restore() }
                }
                .disabled(app.store.isRestoring)
                .accessibilityIdentifier("settings.restore")
                ManageSubscriptionButton(source: app.store.source)
                #if os(iOS)
                    Button("Redeem Offer Code") { isRedeemingCode = true }
                        .offerCodeRedemption(isPresented: $isRedeemingCode) { _ in
                            Task { await app.store.refreshEntitlements() }
                        }
                        .accessibilityIdentifier("settings.redeem")
                #endif
            } header: {
                SectionHeader("RequestPad Pro")
            }
            dataSection
            supportSection
            Section {
                Link("Privacy Policy", destination: AppLinks.privacy)
                Link("Terms of Use", destination: AppLinks.terms)
            } header: {
                SectionHeader("Legal")
            }
            Section {
                LabeledContent("Version", value: Self.versionString)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            #endif
        }
        .confirmationDialog("Erase all data?", isPresented: $isEraseConfirmationPresented, titleVisibility: .visible) {
            Button("Erase All Data", role: .destructive) {
                Task {
                    isWorking = true
                    await app.eraseAllData()
                    isWorking = false
                    isEchoRunning = false
                    dismiss()
                }
            }
        } message: {
            Text(
                "Deletes collections stored in the app, environments, secrets, history, cookies, tokens and settings on this device. Folders you opened stay on disk. This can't be undone."
            )
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .json, defaultFilename: "RequestPad Data"
        ) { _ in exportDocument = nil }
        .fileImporter(isPresented: $isImportPickerPresented, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = app.environment.folderAccess.beginAccess(to: url)
            defer { access.stop() }
            do {
                let data = try Data(contentsOf: url)
                Task { await app.importAppData(data) }
            } catch {
                app.present(DataError.fileReadFailed(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        .sheet(isPresented: $isPaywallPresented) {
            PaywallView(app: app, feature: nil)
        }
        .alert(
            item: Binding(get: { restoreResult.map(RestoreAlert.init) }, set: { if $0 == nil { restoreResult = nil } })
        ) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .sheet(isPresented: Binding(get: { diagnostics != nil }, set: { if !$0 { diagnostics = nil } })) {
            DiagnosticsSheet(text: diagnostics ?? "")
        }
        .task {
            timeoutSeconds = app.preferences.defaultTimeoutSeconds
            followRedirects = app.preferences.followRedirects
            isEchoRunning = await app.environment.echo.isRunning
        }
        .disabled(isWorking)
    }

    #if os(macOS)
        private var macSection: some View {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .accessibilityIdentifier("settings.loginItem")
                if loginItem.needsApproval {
                    Text("Allow RequestPad in System Settings › General › Login Items.")
                        .foregroundStyle(Color.textSecondary)
                    Button("Open Login Items Settings") { loginItem.openSystemSettings() }
                }
                if let message = loginItem.errorMessage {
                    Text(message).foregroundStyle(Color.textOrange)
                }
                Toggle(
                    "Menu Bar Quick Send",
                    isOn: Binding(
                        get: { app.menuBarQuickSendEnabled && app.gate.isPro },
                        set: { enabled in
                            if enabled && !app.gate.isPro {
                                isPaywallPresented = true
                            } else {
                                app.menuBarQuickSendEnabled = enabled
                            }
                        })
                )
                .accessibilityIdentifier("settings.menuBar")
            } header: {
                SectionHeader("Mac")
            } footer: {
                Text(
                    "Quick Send (Pro) adds a menu bar item for sending a saved request or a URL without opening a window."
                )
                .foregroundStyle(Color.textSecondary)
            }
            .onAppear { loginItem.refresh() }
        }
    #endif

    private var echoSection: some View {
        Section {
            Toggle("Local Echo Server", isOn: Binding(get: { isEchoRunning }, set: { toggleEcho($0) }))
                .accessibilityIdentifier("settings.echo")
            if let port = app.echoPort {
                LabeledContent("Address") { Text(verbatim: "http://127.0.0.1:\(port)").textSelection(.enabled) }
            }
            Button("Load Sample Data") {
                Task {
                    isWorking = true
                    await app.loadSampleData()
                    isEchoRunning = await app.environment.echo.isRunning
                    isWorking = false
                }
            }
            .accessibilityIdentifier("settings.loadSample")
        } header: {
            Group {
                Text("Try It Out")
            }
            .foregroundStyle(Color.textSecondary)
        } footer: {
            Group {
                Text(
                    "A small server inside RequestPad that answers on this device only, for trying requests without the internet."
                )
            }
            .foregroundStyle(Color.textSecondary)
        }
    }

    private var dataSection: some View {
        Section {
            Button("Export App Data…") {
                Task { if let data = await app.exportAppData() { exportDocument = AppDataDocument(data: data) } }
            }
            .accessibilityIdentifier("settings.export")
            Button("Import App Data…") { isImportPickerPresented = true }
                .accessibilityIdentifier("settings.import")
            Button("Erase All Data…", role: .destructive) { isEraseConfirmationPresented = true }
                .foregroundStyle(Color.textRed)
                .accessibilityIdentifier("settings.erase")
        } header: {
            Group {
                Text("Your Data")
            }
            .foregroundStyle(Color.textSecondary)
        } footer: {
            Group {
                Text(
                    "RequestPad has no account and no server. Everything stays on this device. Exports don't include secrets."
                )
            }
            .foregroundStyle(Color.textSecondary)
        }
    }

    private var supportSection: some View {
        Section {
            Link("Help & Support", destination: AppLinks.support)
            Link("Email Support", destination: AppConstants.supportMailURL(subject: "RequestPad \(Self.versionString)"))
            Button("View Diagnostics") {
                Task { diagnostics = await app.environment.diagnostics.makeReport().text }
            }
            .accessibilityIdentifier("settings.diagnostics")
            Button("Rate RequestPad") { requestReview() }
        } header: {
            SectionHeader("Support")
        }
    }

    private func toggleEcho(_ enabled: Bool) {
        Task {
            if enabled { await app.startEcho() } else { await app.stopEcho() }
            isEchoRunning = await app.environment.echo.isRunning
        }
    }

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Shows the diagnostics report; the user decides whether to copy or share it (X04.3).
private struct DiagnosticsSheet: View {
    let text: String
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(
                    "This report contains app and device versions, settings, item counts and recent log lines. URLs are reduced to their host. Nothing is sent automatically."
                )
                .font(.footnote)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.medium)
                LargeTextView(text: text, identifier: "diagnostics.text")
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text, subject: Text("RequestPad Diagnostics"))
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Copy") { Clipboard.copy(text) }
                }
            }
        }
        .sheetFrame(minWidth: 560, minHeight: 480)
    }
}

/// Exported app data (JSON, without secrets).
struct AppDataDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
