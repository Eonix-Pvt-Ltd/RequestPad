import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI
import UniformTypeIdentifiers

/// Import from cURL, OpenAPI 3 and Postman v2.1 (F07, P02, P03).
struct ImportView: View {
    enum Source: String, CaseIterable, Identifiable {
        case curl, openAPI, postman
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .curl: "cURL"
            case .openAPI: "OpenAPI"
            case .postman: "Postman"
            }
        }
    }

    /// A parsed document waiting for confirmation.
    private enum Preview {
        case curl(CurlImport)
        case collection(ImportedCollection)
    }

    /// Imported documents larger than this are refused before parsing.
    private static let maximumDocumentBytes = 20 * 1024 * 1024

    let app: AppModel
    let workspace: WorkspaceModel
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var source: Source = .curl
    @State private var text = ""
    @State private var preview: Preview?
    @State private var errorMessage: String?
    @State private var isFilePickerPresented = false
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Import From", selection: $source) {
                    ForEach(Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("import.source")
                .onChange(of: source) { _, _ in
                    preview = nil
                    errorMessage = nil
                }
                inputSection
                previewSection
            }
            .formStyle(.grouped)
            .navigationTitle("Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(preview == nil ? "Preview" : "Import") { preview == nil ? parse() : commit() }
                        .disabled(text.isEmpty || isImporting)
                        .accessibilityIdentifier("import.confirm")
                }
            }
            .fileImporter(isPresented: $isFilePickerPresented, allowedContentTypes: allowedTypes) { result in
                load(result)
            }
        }
        .sheetFrame(minWidth: 480, minHeight: 480)
    }

    private var allowedTypes: [UTType] {
        [.json, .yaml, .plainText].compactMap { $0 }
    }

    @ViewBuilder private var inputSection: some View {
        Section {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(6...16)
                .monospacedField()
                .onChange(of: text) { _, _ in preview = nil }
                .accessibilityLabel(Text("Import text"))
                .accessibilityIdentifier("import.text")
            if source != .curl {
                Button("Choose File…") { isFilePickerPresented = true }
                    .accessibilityIdentifier("import.chooseFile")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.textOrange)
                    .accessibilityIdentifier("import.error")
            }
        } footer: {
            Group {
                Text(footer)
            }
            .foregroundStyle(Color.textSecondary)
        }
    }

    @ViewBuilder private var previewSection: some View {
        switch preview {
        case .curl(let imported):
            Section {
                LabeledContent("Method", value: imported.request.method.rawValue)
                LabeledContent("URL") { Text(verbatim: imported.request.url).font(.callout.monospaced()).lineLimit(3) }
                LabeledContent("Headers", value: "\(imported.request.headers.count)")
                notices(imported.notices)
            } header: {
                SectionHeader("Preview")
            }
        case .collection(let imported):
            Section {
                LabeledContent("Name", value: imported.name)
                LabeledContent("Requests", value: "\(imported.items.count)")
                LabeledContent("Folders", value: "\(imported.folders.count)")
                LabeledContent("Environments", value: "\(imported.environments.count)")
                notices(imported.notices)
            } header: {
                SectionHeader("Preview")
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func notices(_ notices: [String]) -> some View {
        ForEach(notices, id: \.self) { notice in
            Label(notice, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var placeholder: LocalizedStringKey {
        switch source {
        case .curl: "curl https://api.example.com -H 'Accept: application/json'"
        case .openAPI: "Paste an OpenAPI 3 document (JSON or YAML) or choose a file"
        case .postman: "Paste a Postman v2.1 collection or choose a file"
        }
    }

    private var footer: LocalizedStringKey {
        switch source {
        case .curl: "The command is parsed, never run. Unsupported flags are listed before you import."
        case .openAPI: "Creates a collection with a folder per tag and a request per operation."
        case .postman: "Creates a collection with the same folders. Scripts are kept but not run."
        }
    }

    private func load(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let access = app.environment.folderAccess.beginAccess(to: url)
        defer { access.stop() }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumDocumentBytes else {
                errorMessage = String(localized: "The file is larger than 20 MB.")
                return
            }
            let data = try Data(contentsOf: url)
            text = String(decoding: data, as: UTF8.self)
            errorMessage = nil
            parse()
        } catch {
            errorMessage = String(localized: "The file couldn't be read.")
        }
    }

    private func parse() {
        errorMessage = nil
        let data = Data(text.utf8)
        guard data.count <= Self.maximumDocumentBytes else {
            errorMessage = String(localized: "The document is larger than 20 MB.")
            return
        }
        do {
            switch source {
            case .curl: preview = .curl(try CurlParser.parse(text))
            case .openAPI: preview = .collection(try OpenAPIImporter.importDocument(data))
            case .postman: preview = .collection(try PostmanImporter.importDocument(data))
            }
        } catch {
            preview = nil
            errorMessage = error.errorDescription
        }
    }

    private func commit() {
        switch preview {
        case .curl(let imported):
            workspace.openScratch(imported.request)
            dismiss()
        case .collection(let imported):
            isImporting = true
            Task {
                defer { isImporting = false }
                guard let collectionID = await app.importCollection(imported) else { return }
                if let first = app.collection(collectionID)?.tree?.requestsInOrder(under: nil).first {
                    workspace.selection = .request(RequestReference(collectionID: collectionID, key: first.key))
                }
                dismiss()
            }
        case nil:
            parse()
        }
    }
}
