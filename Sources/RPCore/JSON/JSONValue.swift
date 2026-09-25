import Foundation

/// A JSON value that preserves object member order and the exact text of numbers, so documents can be displayed,
/// queried and re-serialized without reordering keys or changing numeric precision.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// The number's literal text as it appeared in the source (e.g. `1`, `-0.5e10`).
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    /// Member lookup; returns the last member with `key` (duplicate keys: last wins, as in most JSON parsers).
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.last(where: { $0.key == key })?.value
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [JSONMember]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Numeric value of a number literal, exact for decimal inputs.
    public var decimalValue: Decimal? {
        if case .number(let literal) = self {
            return Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let literal) = self else { return nil }
        return Int(literal)
    }

    /// Short type name used in UI and error messages.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    public static func number(_ value: Int) -> JSONValue { .number(String(value)) }

    /// Compares values the way users expect: numbers by numeric value (`1 == 1.0`), everything else structurally,
    /// object members regardless of order.
    public func isSemanticallyEqual(to other: JSONValue) -> Bool {
        // Iterative (explicit work list) so deep documents can't overflow the thread stack.
        var work: [(JSONValue, JSONValue)] = [(self, other)]
        while let (lhs, rhs) = work.popLast() {
            switch (lhs, rhs) {
            case (.number, .number):
                guard lhs.decimalValue == rhs.decimalValue else { return false }
            case (.array(let left), .array(let right)):
                guard left.count == right.count else { return false }
                work.append(contentsOf: zip(left, right))
            case (.object(let left), .object(let right)):
                let leftMembers = Dictionary(left.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
                let rightMembers = Dictionary(right.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
                guard leftMembers.count == rightMembers.count else { return false }
                for (key, value) in leftMembers {
                    guard let counterpart = rightMembers[key] else { return false }
                    work.append((value, counterpart))
                }
            default:
                guard lhs == rhs else { return false }
            }
        }
        return true
    }
}

public struct JSONMember: Hashable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}
