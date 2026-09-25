import Foundation

/// Where an extraction rule or assertion reads from in a response (P05, P06).
public enum ResponseSource: Hashable, Sendable, Codable {
    case status
    case header(String)
    /// A JSON path into the parsed body, stored in ``JSONPath`` syntax (`$.data.id`).
    case body(path: String)
    /// Response time in milliseconds.
    case responseTime
}

/// "Set variable `name` from `source` after each successful response" (P05.1).
public struct Extractor: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var variableName: String
    /// `nil` when the `.bru` expression is outside the supported subset; `rawExpression` then holds the original.
    public var source: ResponseSource?
    public var rawExpression: String
    public var isEnabled: Bool
    /// Bruno annotation lines on the `.bru` entry, preserved verbatim.
    public var annotations: [String]

    /// Annotation RequestPad uses to mark "also save to the active environment" in `.bru` files (P05.1).
    public static let persistAnnotation = "@persist"

    public init(
        id: UUID = UUID(), variableName: String, source: ResponseSource?, rawExpression: String,
        isEnabled: Bool = true, annotations: [String] = []
    ) {
        self.id = id
        self.variableName = variableName
        self.source = source
        self.rawExpression = rawExpression
        self.isEnabled = isEnabled
        self.annotations = annotations
    }

    /// Also persist the value into the active environment (P05.1 option).
    public var persistToEnvironment: Bool {
        get { annotations.contains(Self.persistAnnotation) }
        set {
            annotations.removeAll { $0 == Self.persistAnnotation }
            if newValue { annotations.append(Self.persistAnnotation) }
        }
    }

    /// Changes the source and keeps the stored Bruno expression in sync.
    public mutating func setSource(_ newSource: ResponseSource) {
        source = newSource
        rawExpression = BruExpression.format(newSource)
    }

    /// Creates an extractor for a supported source; the Bruno expression is derived from it.
    public init(variableName: String, source: ResponseSource, isEnabled: Bool = true) {
        self.init(
            variableName: variableName, source: source, rawExpression: BruExpression.format(source),
            isEnabled: isEnabled)
    }

    public static func == (lhs: Extractor, rhs: Extractor) -> Bool {
        lhs.variableName == rhs.variableName && lhs.source == rhs.source && lhs.rawExpression == rhs.rawExpression
            && lhs.isEnabled == rhs.isEnabled && lhs.annotations == rhs.annotations
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(variableName)
        hasher.combine(rawExpression)
        hasher.combine(isEnabled)
    }
}

/// A check applied to a response (P06.1). Stored as a Bruno `assert` entry: `res.status: eq 200`.
public struct Assertion: Hashable, Sendable, Codable, Identifiable {
    public enum Operator: String, Hashable, Sendable, Codable, CaseIterable {
        case equals = "eq"
        case notEquals = "neq"
        case contains = "contains"
        case notContains = "notContains"
        case exists = "isDefined"
        case notExists = "isUndefined"
        case greaterThan = "gt"
        case lessThan = "lt"

        /// Operators that take no operand.
        public var isUnary: Bool { self == .exists || self == .notExists }
    }

    public var id: UUID
    /// `nil` when the `.bru` key is outside the supported subset.
    public var source: ResponseSource?
    public var rawKey: String
    /// `nil` when the `.bru` operator is not supported; `rawValue` then holds the original text.
    public var operation: Operator?
    /// Operand as written in the `.bru` file (`200`, `"abc"`, `true`).
    public var operand: String
    public var rawValue: String
    public var isEnabled: Bool
    public var annotations: [String]

    public init(
        id: UUID = UUID(), source: ResponseSource?, rawKey: String, operation: Operator?, operand: String,
        rawValue: String, isEnabled: Bool = true, annotations: [String] = []
    ) {
        self.id = id
        self.source = source
        self.rawKey = rawKey
        self.operation = operation
        self.operand = operand
        self.rawValue = rawValue
        self.isEnabled = isEnabled
        self.annotations = annotations
    }

    /// Bruno assertion operators. Values whose first word is not one of these are compared with `eq` (Bruno).
    public static let bruOperators: Set<String> = [
        "eq", "neq", "gt", "gte", "lt", "lte", "in", "notIn", "contains", "notContains", "length", "matches",
        "notMatches", "startsWith", "endsWith", "between", "isEmpty", "isNotEmpty", "isNull", "isUndefined",
        "isDefined", "isTruthy", "isFalsy", "isJson", "isNumber", "isString", "isBoolean", "isArray",
    ]

    /// Parses a Bruno assertion entry (`key: value`).
    public static func fromBru(key: String, value: String, isEnabled: Bool, annotations: [String]) -> Assertion {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let firstWord = trimmed.prefix(while: { !$0.isWhitespace })
        let rest = trimmed.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces)
        let operation: Operator?
        let operand: String
        if let supported = Operator(rawValue: String(firstWord)) {
            operation = supported.isUnary && !rest.isEmpty ? nil : supported
            operand = supported.isUnary ? "" : rest
        } else if bruOperators.contains(String(firstWord)) {
            operation = nil
            operand = rest
        } else {
            operation = .equals
            operand = trimmed
        }
        return Assertion(
            source: BruExpression.parse(key), rawKey: key, operation: operation, operand: operand, rawValue: value,
            isEnabled: isEnabled, annotations: annotations)
    }

    /// Creates a supported assertion; Bruno key and value text are derived.
    public init(source: ResponseSource, operation: Operator, operand: String = "", isEnabled: Bool = true) {
        let value = operation.isUnary ? operation.rawValue : "\(operation.rawValue) \(operand)"
        self.init(
            source: source, rawKey: BruExpression.format(source), operation: operation,
            operand: operation.isUnary ? "" : operand, rawValue: value, isEnabled: isEnabled)
    }

    public var isSupported: Bool { source != nil && operation != nil }

    public static func == (lhs: Assertion, rhs: Assertion) -> Bool {
        lhs.rawKey == rhs.rawKey && lhs.rawValue == rhs.rawValue && lhs.isEnabled == rhs.isEnabled
            && lhs.annotations == rhs.annotations
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawKey)
        hasher.combine(rawValue)
        hasher.combine(isEnabled)
    }
}
