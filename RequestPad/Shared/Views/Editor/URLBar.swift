import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

/// Method, URL, Send/Cancel and undefined-variable warnings (F01.1, F01.5, F04.3).
struct URLBar: View {
    let editor: RequestEditorModel
    let workspace: WorkspaceModel
    @FocusState private var isURLFocused: Bool
    @State private var isCustomMethodPresented = false
    @State private var customMethod = ""
    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            if dynamicTypeSize.isAccessibilitySize {
                // Large text: the URL gets the full width; method and Send share a row below it.
                urlField
                HStack(spacing: Spacing.small) {
                    methodMenu
                    Spacer(minLength: 0)
                    sendButton
                }
            } else {
                HStack(spacing: Spacing.small) {
                    methodMenu
                    urlField
                    sendButton
                }
            }
            let unresolved = editor.unresolvedVariables
            if !unresolved.isEmpty {
                Label {
                    Text("Undefined variables: \(unresolved.map { "{{\($0)}}" }.joined(separator: ", "))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(Color.textOrange)
                .accessibilityIdentifier("editor.unresolved")
            }
        }
        .onChange(of: workspace.focusURLRequest) { _, _ in isURLFocused = true }
        .alert("Custom Method", isPresented: $isCustomMethodPresented) {
            TextField("Method", text: $customMethod)
                .monospacedField()
            Button("Use") {
                if let method = HTTPMethod(rawValue: customMethod.trimmingCharacters(in: .whitespaces)) {
                    editor.request.method = method
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Letters, digits and !#$%&'*+-.^_`|~ only, up to 32 characters.")
        }
    }

    private var urlField: some View {
        TextField("Enter a URL or paste a cURL command", text: urlBinding, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .monospacedField()
            #if os(iOS)
                .keyboardType(.URL)
                .submitLabel(.send)
            #endif
            .focused($isURLFocused)
            .onSubmit { editor.send() }
            .accessibilityLabel(Text("URL"))
            .accessibilityIdentifier("editor.url")
    }

    private var urlBinding: Binding<String> {
        Binding(get: { editor.request.url }, set: { editor.urlDidChange($0) })
    }

    private var methodMenu: some View {
        Menu {
            ForEach(HTTPMethod.standard, id: \.self) { method in
                Button(method.rawValue) { editor.request.method = method }
            }
            Divider()
            Button("Custom…") {
                customMethod = editor.request.method.isStandard ? "" : editor.request.method.rawValue
                isCustomMethodPresented = true
            }
        } label: {
            MethodBadge(editor.request.method)
                .frame(minWidth: 56, minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel(Text("Method \(editor.request.method.rawValue)"))
        .accessibilityIdentifier("editor.method")
    }

    @ViewBuilder private var sendButton: some View {
        if editor.isSending {
            Button(role: .cancel) {
                editor.cancel()
            } label: {
                Label("Cancel", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("editor.cancel")
        } else {
            Button {
                editor.send()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .prominentButtonStyle()
            .disabled(editor.request.url.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("editor.send")
        }
    }
}
