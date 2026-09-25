import Foundation

/// One row of a key/value table (query params, headers, form fields, variables in `.bru` files).
///
/// `id` exists for SwiftUI identity only and is ignored by equality, so two rows with the same content compare
/// equal. `annotations` holds Bruno annotation lines (e.g. `@description('…')`) verbatim so they survive edits.
public struct KeyValue: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isEnabled: Bool
    public var annotations: [String]

    public init(
        id: UUID = UUID(), name: String, value: String, isEnabled: Bool = true, annotations: [String] = []
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
        self.annotations = annotations
    }

    public static func == (lhs: KeyValue, rhs: KeyValue) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value && lhs.isEnabled == rhs.isEnabled
            && lhs.annotations == rhs.annotations
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(value)
        hasher.combine(isEnabled)
        hasher.combine(annotations)
    }
}

extension Array where Element == KeyValue {
    /// Enabled rows with a non-empty name, in order.
    public var active: [KeyValue] { filter { $0.isEnabled && !$0.name.isEmpty } }

    /// Value of the last enabled row whose name matches case-insensitively (HTTP header semantics).
    public func lastValue(forCaseInsensitiveName name: String) -> String? {
        active.last(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }
}
