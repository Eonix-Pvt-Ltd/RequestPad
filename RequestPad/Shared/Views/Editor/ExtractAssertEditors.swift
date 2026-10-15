import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

/// Where a value is read from in the response, as an editable (kind, argument) pair.
enum SourceKind: String, CaseIterable, Identifiable {
    case status, header, body, responseTime
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .status: "Status Code"
        case .header: "Header"
        case .body: "JSON Body"
        case .responseTime: "Response Time"
        }
    }

    var argumentPlaceholder: LocalizedStringKey? {
        switch self {
        case .header: "Header name"
        case .body: "JSONPath, e.g. $.data.token"
        case .status, .responseTime: nil
        }
    }

    init(_ source: ResponseSource?) {
        switch source {
        case .header: self = .header
        case .body: self = .body
        case .responseTime: self = .responseTime
        case .status, nil: self = .status
        }
    }

    static func argument(of source: ResponseSource?) -> String {
        switch source {
        case .header(let name): name
        case .body(let path): path
        default: ""
        }
    }

    func source(argument: String) -> ResponseSource {
        switch self {
        case .status: .status
        case .header: .header(argument)
        case .body: .body(path: argument.isEmpty ? "$" : argument)
        case .responseTime: .responseTime
        }
    }
}

/// Picker plus argument field for a response source.
private struct SourceFields: View {
    let source: ResponseSource?
    let set: (ResponseSource) -> Void

    var body: some View {
        let kind = SourceKind(source)
        Picker(
            "Source",
            selection: Binding(get: { kind }, set: { set($0.source(argument: SourceKind.argument(of: source))) })
        ) {
            ForEach(SourceKind.allCases) { Text($0.title).tag($0) }
        }
        .fixedSize()
        if let placeholder = kind.argumentPlaceholder {
            TextField(
                placeholder,
                text: Binding(get: { SourceKind.argument(of: source) }, set: { set(kind.source(argument: $0)) })
            )
            .textFieldStyle(.roundedBorder)
            .monospacedField()
        }
    }
}

/// Extraction rules: response value → variable (P05).
struct ExtractorsEditor: View {
    @Binding var extractors: [Extractor]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ForEach($extractors) { $extractor in
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    HStack {
                        Toggle(isOn: $extractor.isEnabled) { Text("\(extractor.variableName) enabled") }
                            .labelsHidden()
                            .toggleStyle(.checkboxCompat)
                        TextField("Variable name", text: $extractor.variableName)
                            .textFieldStyle(.roundedBorder)
                            .monospacedField()
                            .accessibilityIdentifier("extract.name")
                        Button(role: .destructive) {
                            extractors.removeAll { $0.id == extractor.id }
                        } label: {
                            Label("Delete", systemImage: "minus.circle").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .minimumHitTarget()
                        .accessibilityLabel(Text("Delete rule \(extractor.variableName)"))
                    }
                    if extractor.source == nil {
                        Text("Unsupported expression “\(extractor.rawExpression)” is kept but not evaluated.")
                            .font(.footnote)
                            .foregroundStyle(Color.textSecondary)
                    }
                    HStack {
                        SourceFields(source: extractor.source) { extractor.setSource($0) }
                    }
                    Toggle("Save to Active Environment", isOn: $extractor.persistToEnvironment)
                    if !extractor.variableName.isEmpty, !Variable.isValidName(extractor.variableName) {
                        Text("Use letters, digits, “_”, “-” or “.” only.")
                            .font(.footnote)
                            .foregroundStyle(Color.textOrange)
                    }
                }
                .padding(Spacing.small)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            Button {
                extractors.append(Extractor(variableName: "", source: .body(path: "$")))
            } label: {
                Label("Add Rule", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("extract.add")
            Text("Extracted values are available as {{name}} in later requests of this collection until the app quits.")
                .font(.footnote)
                .foregroundStyle(Color.textSecondary)
        }
    }
}

/// Assertions checked after every send (P06.1).
struct AssertionsEditor: View {
    @Binding var assertions: [Assertion]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ForEach($assertions) { $assertion in
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    HStack {
                        Toggle(isOn: $assertion.isEnabled) { Text("Assertion enabled") }
                            .labelsHidden()
                            .toggleStyle(.checkboxCompat)
                        if assertion.isSupported {
                            SourceFields(source: assertion.source) { update(&assertion, source: $0) }
                        } else {
                            Text(verbatim: "\(assertion.rawKey): \(assertion.rawValue)")
                                .font(.callout.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button(role: .destructive) {
                            assertions.removeAll { $0.id == assertion.id }
                        } label: {
                            Label("Delete", systemImage: "minus.circle").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .minimumHitTarget()
                        .accessibilityLabel(Text("Delete assertion"))
                    }
                    if let operation = assertion.operation, assertion.isSupported {
                        HStack {
                            Picker(
                                "Operator",
                                selection: Binding(get: { operation }, set: { update(&assertion, operation: $0) })
                            ) {
                                ForEach(Assertion.Operator.allCases, id: \.self) { Text(Self.title(for: $0)).tag($0) }
                            }
                            .fixedSize()
                            if !operation.isUnary {
                                TextField(
                                    "Expected value",
                                    text: Binding(get: { assertion.operand }, set: { update(&assertion, operand: $0) })
                                )
                                .textFieldStyle(.roundedBorder)
                                .monospacedField()
                                .accessibilityIdentifier("assert.operand")
                            }
                        }
                    } else {
                        Text(
                            "RequestPad doesn't evaluate this assertion yet; it is kept in the file and reported as skipped."
                        )
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                    }
                }
                .padding(Spacing.small)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            Button {
                assertions.append(Assertion(source: .status, operation: .equals, operand: "200"))
            } label: {
                Label("Add Assertion", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("assert.add")
        }
    }

    private func update(
        _ assertion: inout Assertion, source: ResponseSource? = nil, operation: Assertion.Operator? = nil,
        operand: String? = nil
    ) {
        guard let currentSource = source ?? assertion.source, let currentOperation = operation ?? assertion.operation
        else { return }
        var updated = Assertion(
            source: currentSource, operation: currentOperation, operand: operand ?? assertion.operand,
            isEnabled: assertion.isEnabled)
        updated.id = assertion.id
        updated.annotations = assertion.annotations
        assertion = updated
    }

    static func title(for operation: Assertion.Operator) -> LocalizedStringKey {
        switch operation {
        case .equals: "equals"
        case .notEquals: "does not equal"
        case .contains: "contains"
        case .notContains: "does not contain"
        case .exists: "exists"
        case .notExists: "does not exist"
        case .greaterThan: "is greater than"
        case .lessThan: "is less than"
        }
    }
}
