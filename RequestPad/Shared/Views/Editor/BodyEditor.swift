import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI
import UniformTypeIdentifiers

/// Request body by mode (F01.3), including multipart files (F01.4) and GraphQL (P04).
struct BodyEditor: View {
    enum Mode: String, CaseIterable, Identifiable {
        case none, json, text, xml, form, multipart, graphQL
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .none: "None"
            case .json: "JSON"
            case .text: "Text"
            case .xml: "XML"
            case .form: "Form URL-Encoded"
            case .multipart: "Multipart Form"
            case .graphQL: "GraphQL"
            }
        }

        init?(_ body: RequestBody) {
            switch body {
            case .none: self = .none
            case .json: self = .json
            case .text: self = .text
            case .xml: self = .xml
            case .formURLEncoded: self = .form
            case .multipart: self = .multipart
            case .graphQL: self = .graphQL
            case .unsupported: return nil
            }
        }
    }

    let editor: RequestEditorModel

    var body: some View {
        Picker("Body", selection: modeBinding) {
            ForEach(Mode.allCases) { mode in
                Text(mode.title).tag(Optional(mode))
            }
            if Mode(editor.request.body) == nil {
                Text("Unsupported (\(editor.request.body.bruMode))").tag(Mode?.none)
            }
        }
        .accessibilityIdentifier("editor.body.mode")
        content
    }

    /// Switching modes keeps text where it makes sense (JSON ↔ text ↔ XML).
    private var modeBinding: Binding<Mode?> {
        Binding(
            get: { Mode(editor.request.body) },
            set: { newValue in
                guard let newValue, newValue != Mode(editor.request.body) else { return }
                let text = Self.text(of: editor.request.body)
                switch newValue {
                case .none: editor.request.body = .none
                case .json: editor.request.body = .json(text)
                case .text: editor.request.body = .text(text)
                case .xml: editor.request.body = .xml(text)
                case .form: editor.request.body = .formURLEncoded([])
                case .multipart: editor.request.body = .multipart([])
                case .graphQL:
                    editor.request.body = .graphQL(GraphQLBody())
                    if editor.request.method == .get { editor.request.method = .post }
                }
                if newValue == .graphQL { editor.request.kind = .graphql } else { editor.request.kind = .http }
            })
    }

    private static func text(of body: RequestBody) -> String {
        switch body {
        case .json(let text), .text(let text), .xml(let text): text
        default: ""
        }
    }

    @ViewBuilder private var content: some View {
        switch editor.request.body {
        case .none:
            Text("This request has no body.")
                .foregroundStyle(Color.textSecondary)
        case .json(let text):
            JSONBodyEditor(
                text: Binding(get: { text }, set: { editor.request.body = .json($0) }))
        case .text(let text):
            CodeEditor(
                text: Binding(get: { text }, set: { editor.request.body = .text($0) }), label: "Body",
                identifier: "editor.body.text"
            )
            .frame(minHeight: 240)
        case .xml(let text):
            CodeEditor(
                text: Binding(get: { text }, set: { editor.request.body = .xml($0) }), label: "XML body",
                identifier: "editor.body.xml"
            )
            .frame(minHeight: 240)
        case .formURLEncoded(let rows):
            KeyValueEditor(
                rows: Binding(get: { rows }, set: { editor.request.body = .formURLEncoded($0) }),
                identifier: "editor.body.form")
        case .multipart(let fields):
            MultipartEditor(
                fields: Binding(get: { fields }, set: { editor.request.body = .multipart($0) }), editor: editor)
        case .graphQL(let body):
            GraphQLEditor(body: Binding(get: { body }, set: { editor.request.body = .graphQL($0) }), editor: editor)
        case .unsupported(let mode):
            Text("RequestPad can't edit “\(mode)” bodies. The body is kept when the file is saved.")
                .foregroundStyle(Color.textSecondary)
        }
    }
}

/// JSON text with validation and formatting.
private struct JSONBodyEditor: View {
    @Binding var text: String

    var body: some View {
        let problem = validationMessage
        HStack {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.textOrange)
                    .accessibilityIdentifier("editor.body.jsonError")
            } else if !text.isEmpty {
                Label("Valid JSON", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Button("Format") {
                if let value = try? JSONParser().parse(text) { text = JSONSerializer.string(from: value) }
            }
            .buttonStyle(.bordered)
            .disabled(problem != nil || text.isEmpty)
            .accessibilityIdentifier("editor.body.format")
        }
        CodeEditor(text: $text, label: "JSON body", identifier: "editor.body.json")
            .frame(minHeight: 240)
    }

    /// Bodies with `{{variables}}` are validated after replacing each with a placeholder value.
    private var validationMessage: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = text
        for token in Interpolator.tokens(in: text).reversed() {
            candidate.replaceSubrange(token.range, with: "0")
        }
        do {
            _ = try JSONParser().parse(candidate)
            return nil
        } catch {
            return error.errorDescription
        }
    }
}

/// Multipart fields: text values or files (F01.4).
private struct MultipartEditor: View {
    @Binding var fields: [MultipartField]
    let editor: RequestEditorModel
    @State private var pickingFor: MultipartField.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach($fields) { $field in
                fieldRow($field)
            }
            HStack {
                Button {
                    fields.append(MultipartField(name: "", content: .text("")))
                } label: {
                    Label("Add Text Field", systemImage: "plus")
                }
                Button {
                    let field = MultipartField(name: "file", content: .files([]))
                    fields.append(field)
                    pickingFor = field.id
                } label: {
                    Label("Add File", systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("editor.body.multipart.addFile")
            }
            .buttonStyle(.borderless)
        }
        .fileImporter(
            isPresented: Binding(get: { pickingFor != nil }, set: { if !$0 { pickingFor = nil } }),
            allowedContentTypes: [.item],
            allowsMultipleSelection: true, onCompletion: attach)
    }

    private func fieldRow(_ field: Binding<MultipartField>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Toggle(isOn: field.isEnabled) { Text("\(field.wrappedValue.name) enabled") }
                .labelsHidden()
                .toggleStyle(.checkboxCompat)
            TextField("Name", text: field.name)
                .textFieldStyle(.roundedBorder)
                .monospacedField()
                .frame(maxWidth: 160)
            switch field.wrappedValue.content {
            case .text(let value):
                TextField(
                    "Value", text: Binding(get: { value }, set: { field.wrappedValue.content = .text($0) }),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .monospacedField()
            case .files(let references):
                VStack(alignment: .leading) {
                    ForEach(references, id: \.self) { reference in
                        Label(
                            BookmarkFileResolver.displayName(
                                for: reference, folderAccess: editor.app.environment.folderAccess),
                            systemImage: "doc")
                    }
                    Button(references.isEmpty ? "Choose Files…" : "Change Files…") {
                        pickingFor = field.wrappedValue.id
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(role: .destructive) {
                fields.removeAll { $0.id == field.wrappedValue.id }
            } label: {
                Label("Delete", systemImage: "minus.circle").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .minimumHitTarget()
            .accessibilityLabel(Text("Delete \(field.wrappedValue.name)"))
        }
    }

    private func attach(_ result: Result<[URL], Error>) {
        guard let id = pickingFor, case .success(let urls) = result,
            let index = fields.firstIndex(where: { $0.id == id })
        else {
            pickingFor = nil
            return
        }
        pickingFor = nil
        let folderRoot = editor.reference.flatMap {
            editor.app.collection($0.collectionID)?.session as? FolderCollectionSession
        }?.root
        var references: [String] = []
        for url in urls {
            do {
                references.append(
                    try BookmarkFileResolver.reference(
                        for: url, baseDirectory: folderRoot, folderAccess: editor.app.environment.folderAccess))
            } catch {
                editor.app.present(error)
            }
        }
        if !references.isEmpty { fields[index].content = .files(references) }
    }
}
