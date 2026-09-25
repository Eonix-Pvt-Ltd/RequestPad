import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI

/// The request's editable sections (F01.2–F01.4, F05, P05, P06).
struct RequestEditorTabs: View {
    enum Tab: String, CaseIterable, Identifiable {
        case params, headers, body, auth, vars, extract, assert, settings, docs
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .params: "Params"
            case .headers: "Headers"
            case .body: "Body"
            case .auth: "Auth"
            case .vars: "Vars"
            case .extract: "Extract"
            case .assert: "Assert"
            case .settings: "Settings"
            case .docs: "Docs"
            }
        }
    }

    let editor: RequestEditorModel
    @SceneStorage("editor.tab") private var tab: Tab = .params

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xSmall) {
                    ForEach(Tab.allCases) { item in
                        tabButton(item)
                    }
                }
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.xSmall)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.tabs")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    section
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func tabButton(_ item: Tab) -> some View {
        let count = count(for: item)
        let isSelected = tab == item
        return Button {
            tab = item
        } label: {
            HStack(spacing: Spacing.xxSmall) {
                Text(item.title)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xSmall)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(count > 0 ? Text("\(Text(item.title)), \(count)") : Text(item.title))
        .accessibilityIdentifier("editor.tab.\(item.rawValue)")
    }

    private func count(for item: Tab) -> Int {
        let request = editor.request
        switch item {
        case .params: return request.queryParams.active.count + request.pathParams.active.count
        case .headers: return request.headers.active.count
        case .vars: return request.variables.active.count
        case .extract: return request.extractors.filter(\.isEnabled).count
        case .assert: return request.assertions.filter(\.isEnabled).count
        case .body, .auth, .settings, .docs: return 0
        }
    }

    @ViewBuilder private var section: some View {
        @Bindable var editor = editor
        switch tab {
        case .params:
            FieldRow(title: "Query Parameters") {
                KeyValueEditor(
                    rows: Binding(get: { editor.request.queryParams }, set: { editor.queryParamsDidChange($0) }),
                    isReadOnly: editor.isReadOnly, identifier: "editor.query")
            }
            FieldRow(title: "Path Parameters") {
                KeyValueEditor(
                    rows: $editor.request.pathParams, isReadOnly: editor.isReadOnly, identifier: "editor.path")
                Text("Use :name in the URL path, e.g. /users/:id.")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
            }
        case .headers:
            KeyValueEditor(rows: $editor.request.headers, isReadOnly: editor.isReadOnly, identifier: "editor.headers")
            Text(
                "Headers from the folder and collection are added when the request is sent. Request headers take precedence."
            )
            .font(.footnote)
            .foregroundStyle(Color.textSecondary)
        case .body:
            BodyEditor(editor: editor)
        case .auth:
            AuthEditor(
                app: editor.app, auth: $editor.request.auth, isReadOnly: editor.isReadOnly,
                tokenActions: OAuthTokenActions(
                    message: editor.oauthMessage,
                    getNewToken: { Task { await editor.getNewToken() } },
                    clearToken: { Task { await editor.clearToken() } }))
        case .vars:
            KeyValueEditor(rows: $editor.request.variables, isReadOnly: editor.isReadOnly, identifier: "editor.vars")
            Text(
                "Request variables override folder and collection variables. Environment and runtime values override them."
            )
            .font(.footnote)
            .foregroundStyle(Color.textSecondary)
        case .extract:
            if editor.app.gate.isPro {
                ExtractorsEditor(extractors: $editor.request.extractors, isReadOnly: editor.isReadOnly)
            } else {
                ProLockedView(
                    app: editor.app, feature: .extractionRules,
                    message:
                        "Save values from responses into variables, for example a login token for the next request.")
            }
        case .assert:
            if editor.app.gate.isPro {
                AssertionsEditor(assertions: $editor.request.assertions, isReadOnly: editor.isReadOnly)
            } else {
                ProLockedView(
                    app: editor.app, feature: .assertionsAndRunner,
                    message: "Check status codes, headers and JSON values on every send, and run whole collections.")
            }
        case .settings:
            RequestSettingsEditor(settings: $editor.request.settings)
                .disabled(editor.isReadOnly)
        case .docs:
            DocsEditor(docs: $editor.request.docs, isReadOnly: editor.isReadOnly)
        }
    }
}

/// Redirects and timeout for one request (F01.6, F01.7).
private struct RequestSettingsEditor: View {
    @Binding var settings: RequestSettings

    var body: some View {
        Toggle("Follow Redirects", isOn: $settings.followRedirects)
            .accessibilityIdentifier("editor.settings.redirects")
        if settings.followRedirects {
            Stepper(value: $settings.maximumRedirects, in: 0...RequestDefaults.maximumRedirects) {
                Text("Maximum Redirects: \(settings.maximumRedirects)")
            }
        }
        FieldRow(title: "Timeout") {
            HStack {
                TextField("Default", value: timeoutSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                    .accessibilityLabel(Text("Timeout in seconds"))
                    .accessibilityIdentifier("editor.settings.timeout")
                Text("seconds")
                    .foregroundStyle(Color.textSecondary)
            }
        }
        Text("Leave empty to use the default from Settings. Timeouts are limited to 1–600 seconds.")
            .font(.footnote)
            .foregroundStyle(Color.textSecondary)
    }

    private var timeoutSeconds: Binding<Int?> {
        Binding(
            get: { settings.timeoutMilliseconds.map { $0 / 1000 } },
            set: { settings.timeoutMilliseconds = $0.map { min(max($0, 1), 600) * 1000 } })
    }
}

/// Markdown notes with a preview (F01.8).
struct DocsEditor: View {
    @Binding var docs: String
    let isReadOnly: Bool
    @State private var isPreviewing = false

    var body: some View {
        Picker("Mode", selection: $isPreviewing) {
            Text("Edit").tag(false)
            Text("Preview").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if isPreviewing {
            Group {
                if docs.isEmpty {
                    Text("No documentation yet.").foregroundStyle(Color.textSecondary)
                } else {
                    Text(markdown)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("editor.docs.preview")
        } else {
            CodeEditor(text: $docs, label: "Documentation", identifier: "editor.docs", isReadOnly: isReadOnly)
                .frame(minHeight: 240)
        }
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: docs, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(docs)
    }
}
