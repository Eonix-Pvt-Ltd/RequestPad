import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

/// GraphQL query and variables with syntax diagnostics, schema fetch and completions (P04).
struct GraphQLEditor: View {
    @Binding var body_: GraphQLBody
    let editor: RequestEditorModel
    /// Cursor position in Unicode scalars (end of the query where the OS can't report the selection).
    @State private var cursorOffset: Int?

    init(body: Binding<GraphQLBody>, editor: RequestEditorModel) {
        _body_ = body
        self.editor = editor
    }

    var body: some View {
        schemaBar
        FieldRow(title: "Query") {
            QueryTextEditor(text: $body_.query, cursorOffset: $cursorOffset)
        }
        let diagnostics = GraphQLValidator.diagnostics(for: body_.query)
        if let first = diagnostics.first {
            Label(
                "Line \(first.position.line), column \(first.position.column): \(first.message)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(Color.textOrange)
            .accessibilityIdentifier("graphql.diagnostic")
        }
        if let schema = editor.schema {
            completions(schema: schema)
        }
        FieldRow(title: "Variables (JSON)") {
            CodeEditor(
                text: $body_.variables, label: "GraphQL variables", identifier: "graphql.variables"
            )
            .frame(minHeight: 100)
        }
        .task(id: editor.request.url) { await editor.loadCachedSchema() }
    }

    private var schemaBar: some View {
        HStack(spacing: Spacing.small) {
            if editor.isFetchingSchema {
                ProgressView().controlSize(.small)
                Text("Fetching schema…").foregroundStyle(Color.textSecondary)
            } else if let schema = editor.schema {
                Label("Schema loaded (\(schema.types.count) types)", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.textSecondary)
            } else if let error = editor.schemaError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.textOrange)
            } else {
                Text("Fetch the schema for autocomplete.").foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Button(editor.schema == nil ? "Fetch Schema" : "Refresh Schema") { Task { await editor.fetchSchema() } }
                .buttonStyle(.bordered)
                .disabled(editor.isFetchingSchema)
                .accessibilityIdentifier("graphql.fetchSchema")
        }
        .font(.footnote)
    }

    private func completions(schema: GraphQLSchema) -> some View {
        let offset = cursorOffset ?? body_.query.unicodeScalars.count
        let suggestions = Array(
            GraphQLCompleter.completions(in: body_.query, cursorOffset: offset, schema: schema).prefix(12))
        return Group {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xSmall) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                insert(suggestion.label, at: offset)
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: suggestion.label)
                                        .font(.callout.monospaced())
                                        .strikethrough(suggestion.isDeprecated)
                                    Text(verbatim: suggestion.detail)
                                        .font(.caption2)
                                        .foregroundStyle(Color.textSecondary)
                                }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel(Text("Insert \(suggestion.label), \(suggestion.detail)"))
                        }
                    }
                }
                .accessibilityIdentifier("graphql.completions")
            }
        }
    }

    /// Replaces the partial name before the cursor with `label`.
    private func insert(_ label: String, at offset: Int) {
        var scalars = Array(body_.query.unicodeScalars)
        let cursor = min(max(offset, 0), scalars.count)
        var start = cursor
        while start > 0, GraphQLLexer.isNameContinue(scalars[start - 1]) { start -= 1 }
        scalars.replaceSubrange(start..<cursor, with: label.unicodeScalars)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        body_.query = String(view)
        cursorOffset = start + label.unicodeScalars.count
    }
}

/// Monospaced query editor that reports the cursor where the OS supports text selection bindings.
private struct QueryTextEditor: View {
    @Binding var text: String
    @Binding var cursorOffset: Int?

    var body: some View {
        Group {
            if #available(iOS 18, macOS 15, *) {
                SelectionTrackingEditor(text: $text, cursorOffset: $cursorOffset)
            } else {
                TextEditor(text: $text)
                    .onChange(of: text) { _, _ in cursorOffset = nil }
            }
        }
        .font(.body.monospaced())
        .autocorrectionDisabled()
        #if os(iOS)
            .textInputAutocapitalization(.never)
        #endif
        .scrollContentBackground(.hidden)
        .padding(Spacing.xSmall)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: 180)
        .accessibilityLabel(Text("GraphQL query"))
        .accessibilityIdentifier("graphql.query")
    }
}

@available(iOS 18, macOS 15, *)
private struct SelectionTrackingEditor: View {
    @Binding var text: String
    @Binding var cursorOffset: Int?
    @State private var selection: TextSelection?

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .onChange(of: selection) { _, newValue in
                guard let newValue, case .selection(let range) = newValue.indices,
                    range.upperBound <= text.endIndex
                else { return }
                cursorOffset = text.unicodeScalars.distance(from: text.startIndex, to: range.upperBound)
            }
    }
}
