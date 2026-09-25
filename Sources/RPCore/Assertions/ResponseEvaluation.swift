import Foundation

/// The parts of a response that extractors and assertions read (P05, P06). Built by the services layer.
public struct ResponseSnapshot: Sendable {
    public var statusCode: Int
    public var headers: [(name: String, value: String)]
    /// Parsed body when it is JSON (and small enough to parse); `nil` otherwise.
    public var jsonBody: JSONValue?
    public var responseTimeMilliseconds: Int

    public init(
        statusCode: Int, headers: [(name: String, value: String)] = [], jsonBody: JSONValue? = nil,
        responseTimeMilliseconds: Int = 0
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.jsonBody = jsonBody
        self.responseTimeMilliseconds = responseTimeMilliseconds
    }

    public enum Lookup: Hashable, Sendable {
        case value(JSONValue)
        case missing
        case bodyIsNotJSON
        case invalidPath(String)
    }

    public func lookup(_ source: ResponseSource) -> Lookup {
        switch source {
        case .status: return .value(.number(statusCode))
        case .responseTime: return .value(.number(responseTimeMilliseconds))
        case .header(let name):
            // Multiple fields with the same name are combined as in RFC 9110 §5.3.
            let values = headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
            return values.isEmpty ? .missing : .value(.string(values.joined(separator: ", ")))
        case .body(let path):
            guard let jsonBody else { return .bodyIsNotJSON }
            do {
                let matches = try JSONPath(path).evaluate(jsonBody)
                guard let first = matches.first else { return .missing }
                return .value(matches.count == 1 ? first.value : .array(matches.map(\.value)))
            } catch {
                return .invalidPath(error.errorDescription ?? path)
            }
        }
    }
}

public struct ExtractionResult: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case extracted(String)
        case notFound
        case failed(String)
    }

    public var variableName: String
    public var outcome: Outcome
    public var persistToEnvironment: Bool
}

public struct AssertionResult: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case passed
        case failed(String)
        /// The assertion is disabled or outside the supported subset.
        case skipped(String)
    }

    public var assertion: Assertion
    public var outcome: Outcome

    public var didPass: Bool { outcome == .passed }
    public var didFail: Bool {
        if case .failed = outcome { return true }
        return false
    }
}

/// Evaluates extraction rules and assertions against a response without any script engine.
public enum ResponseEvaluator {
    /// Runs enabled extractors. Values are scalars as text; objects and arrays as compact JSON.
    /// Bruno's `@name` (local variable) prefix is removed from the variable name.
    public static func extract(_ extractors: [Extractor], from response: ResponseSnapshot) -> [ExtractionResult] {
        extractors.filter(\.isEnabled).map { extractor in
            let name =
                extractor.variableName.hasPrefix("@")
                ? String(extractor.variableName.dropFirst()) : extractor.variableName
            guard let source = extractor.source else {
                return ExtractionResult(
                    variableName: name,
                    outcome: .failed("“\(extractor.rawExpression)” needs scripting, which RequestPad doesn't run."),
                    persistToEnvironment: extractor.persistToEnvironment)
            }
            let outcome: ExtractionResult.Outcome
            switch response.lookup(source) {
            case .value(let value): outcome = .extracted(text(of: value))
            case .missing: outcome = .notFound
            case .bodyIsNotJSON: outcome = .failed("The response body isn't JSON.")
            case .invalidPath(let reason): outcome = .failed(reason)
            }
            return ExtractionResult(
                variableName: name, outcome: outcome, persistToEnvironment: extractor.persistToEnvironment)
        }
    }

    /// Evaluates assertions. `interpolate` substitutes `{{variables}}` in operands.
    public static func evaluate(
        _ assertions: [Assertion], against response: ResponseSnapshot, interpolate: (String) -> String = { $0 }
    ) -> [AssertionResult] {
        assertions.map { assertion in
            AssertionResult(
                assertion: assertion, outcome: outcome(of: assertion, response: response, interpolate: interpolate))
        }
    }

    private static func outcome(
        of assertion: Assertion, response: ResponseSnapshot, interpolate: (String) -> String
    ) -> AssertionResult.Outcome {
        guard assertion.isEnabled else { return .skipped("Disabled") }
        guard let source = assertion.source, let operation = assertion.operation else {
            return .skipped("“\(assertion.rawKey): \(assertion.rawValue)” isn't supported without scripting.")
        }
        let lookup = response.lookup(source)
        let actual: JSONValue?
        switch lookup {
        case .value(let value): actual = value
        case .missing: actual = nil
        case .bodyIsNotJSON: return .failed("The response body isn't JSON.")
        case .invalidPath(let reason): return .failed(reason)
        }
        let expected = operand(interpolate(assertion.operand))
        let actualText = actual.map(text(of:)) ?? "undefined"
        switch operation {
        case .exists:
            return actual != nil ? .passed : .failed("Expected a value, but it is missing.")
        case .notExists:
            return actual == nil ? .passed : .failed("Expected no value, but found \(truncated(actualText)).")
        case .equals, .notEquals:
            let isEqual = actual.map { equal($0, expected) } ?? false
            if isEqual == (operation == .equals) { return .passed }
            return .failed(
                operation == .equals
                    ? "Expected \(truncated(text(of: expected))), got \(truncated(actualText))."
                    : "Expected anything but \(truncated(text(of: expected))).")
        case .contains, .notContains:
            guard let actual else { return .failed("Expected a value, but it is missing.") }
            let found = contains(actual, expected)
            if found == (operation == .contains) { return .passed }
            return .failed(
                operation == .contains
                    ? "\(truncated(actualText)) doesn't contain \(truncated(text(of: expected)))."
                    : "\(truncated(actualText)) contains \(truncated(text(of: expected))).")
        case .greaterThan, .lessThan:
            guard let lhs = actual.flatMap(number), let rhs = number(expected) else {
                return .failed("Expected numbers to compare, got \(truncated(actualText)).")
            }
            let passed = operation == .greaterThan ? lhs > rhs : lhs < rhs
            return passed
                ? .passed
                : .failed(
                    "\(actualText) is not \(operation == .greaterThan ? "greater" : "less") than \(text(of: expected))."
                )
        }
    }

    /// Interprets a Bruno operand: quoted strings, numbers, booleans, null; anything else is a plain string.
    static func operand(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, let quote = trimmed.first, quote == "\"" || quote == "'", trimmed.last == quote {
            return .string(String(trimmed.dropFirst().dropLast()))
        }
        switch trimmed {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: break
        }
        if let value = try? JSONParser(maximumDepth: 32).parse(trimmed) { return value }
        return .string(trimmed)
    }

    static func equal(_ actual: JSONValue, _ expected: JSONValue) -> Bool {
        if actual.isSemanticallyEqual(to: expected) { return true }
        // A header or text value "200" equals the number 200.
        switch (actual, expected) {
        case (.string(let text), .number): return number(.string(text)).map { $0 == expected.decimalValue } ?? false
        case (.number, .string(let text)): return number(.string(text)).map { $0 == actual.decimalValue } ?? false
        default: return false
        }
    }

    static func contains(_ actual: JSONValue, _ expected: JSONValue) -> Bool {
        switch actual {
        case .string(let text): return text.contains(Self.text(of: expected))
        case .array(let elements): return elements.contains { equal($0, expected) }
        case .object(let members):
            if case .string(let key) = expected { return members.contains { $0.key == key } }
            return false
        default: return Self.text(of: actual).contains(Self.text(of: expected))
        }
    }

    static func number(_ value: JSONValue) -> Decimal? {
        switch value {
        case .number: return value.decimalValue
        case .string(let text):
            return Decimal(string: text.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
        default: return nil
        }
    }

    static func text(of value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let text), .string(let text): text
        case .array, .object: JSONSerializer.string(from: value, style: .compact)
        }
    }

    private static func truncated(_ text: String) -> String {
        text.count > 120 ? String(text.prefix(117)) + "…" : text
    }
}
