import RPCore
import SwiftUI

/// Editable table of name/value rows (params, headers, form fields, variables). Each row has an enable toggle,
/// name and value fields and a delete button; a trailing empty row adds new entries. Fully keyboard and
/// VoiceOver operable (B8).
public struct KeyValueEditor: View {
    @Binding var rows: [KeyValue]
    let namePlaceholder: LocalizedStringKey
    let valuePlaceholder: LocalizedStringKey
    let isReadOnly: Bool
    let identifier: String

    public init(
        rows: Binding<[KeyValue]>, namePlaceholder: LocalizedStringKey = "Name",
        valuePlaceholder: LocalizedStringKey = "Value",
        isReadOnly: Bool = false, identifier: String
    ) {
        _rows = rows
        self.namePlaceholder = namePlaceholder
        self.valuePlaceholder = valuePlaceholder
        self.isReadOnly = isReadOnly
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            ForEach($rows) { $row in
                HStack(spacing: Spacing.small) {
                    Toggle(isOn: $row.isEnabled) {
                        Text(row.name.isEmpty ? "Row enabled" : "\(row.name) enabled")
                    }
                    .labelsHidden()
                    .toggleStyle(.checkboxCompat)
                    TextField(namePlaceholder, text: $row.name)
                        .textFieldStyle(.roundedBorder)
                        .monospacedField()
                        .accessibilityLabel(Text("Name"))
                    TextField(valuePlaceholder, text: $row.value, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .monospacedField()
                        .accessibilityLabel(Text("Value for \(row.name)"))
                    Button(role: .destructive) {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Label("Delete", systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .minimumHitTarget()
                    .accessibilityLabel(Text("Delete \(row.name.isEmpty ? "row" : row.name)"))
                }
                .opacity(row.isEnabled ? 1 : 0.6)
            }
            .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
            Button {
                rows.append(KeyValue(name: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("\(identifier).add")
        }
        .disabled(isReadOnly)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// Monospaced, no autocorrection or capitalization — for identifiers, URLs, headers and code (F01).
    public func monospacedField() -> some View {
        #if os(iOS)
            self.font(.body.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        #else
            self.font(.body.monospaced())
                .autocorrectionDisabled()
        #endif
    }
}

extension View {
    /// Pads small icon buttons to the 44×44 pt minimum touch target on iOS (HIG, B8); no change on macOS.
    public func minimumHitTarget() -> some View {
        #if os(iOS)
            self.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
            self
        #endif
    }
}

/// Uses a checkbox on macOS and a switch elsewhere.
public struct CheckboxCompatToggleStyle: ToggleStyle {
    public func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
            Toggle(configuration).toggleStyle(.checkbox)
        #else
            Toggle(configuration).toggleStyle(.switch)
        #endif
    }
}

extension ToggleStyle where Self == CheckboxCompatToggleStyle {
    public static var checkboxCompat: CheckboxCompatToggleStyle { CheckboxCompatToggleStyle() }
}
