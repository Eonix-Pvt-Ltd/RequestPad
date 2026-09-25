import Foundation

/// A JSONPath expression (RFC 9535 subset, F02.4): `$`, `.name`, `['name']`, `[0]`, `[-1]`, `[start:end]`,
/// `[0,2]`, `['a','b']`, `*`, `[*]` and recursive descent `..`. Filter expressions (`?()`) are not supported.
/// Paths may omit the leading `$` (`data.items[0]` means `$.data.items[0]`).
public struct JSONPath: Hashable, Sendable, CustomStringConvertible {
    public enum Selector: Hashable, Sendable {
        case name(String)
        case index(Int)
        case slice(start: Int?, end: Int?)
        case wildcard
        case union([Selector])
    }

    public struct Step: Hashable, Sendable {
        public var selector: Selector
        public var isRecursive: Bool
    }

    /// A location in a document: object keys and array indexes from the root.
    public enum Segment: Hashable, Sendable {
        case key(String)
        case index(Int)
    }

    public struct Match: Hashable, Sendable {
        public var location: [Segment]
        public var value: JSONValue
    }

    /// Maximum matches returned; larger results are truncated so a `$..*` on a big document stays responsive.
    public static let maximumMatches = 10_000

    public let steps: [Step]
    public let source: String

    public init(_ expression: String) throws(CoreError) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidJSONPath(reason: "The path is empty") }
        guard trimmed.utf8.count <= 4096 else { throw .invalidJSONPath(reason: "The path is too long") }
        let normalized: String
        if trimmed.hasPrefix("$") {
            normalized = trimmed
        } else if trimmed.hasPrefix("[") || trimmed.hasPrefix(".") {
            normalized = "$" + trimmed
        } else {
            normalized = "$." + trimmed
        }
        var parser = JSONPathParser(text: Array(normalized.unicodeScalars))
        steps = try parser.parse()
        source = normalized
    }

    public var description: String { source }

    /// The path as plain keys/indexes when it has no wildcards, slices, unions, negative indexes or recursion.
    public var simpleSegments: [Segment]? {
        var segments: [Segment] = []
        for step in steps {
            guard !step.isRecursive else { return nil }
            switch step.selector {
            case .name(let name): segments.append(.key(name))
            case .index(let index) where index >= 0: segments.append(.index(index))
            default: return nil
            }
        }
        return segments
    }

    /// Evaluates the path against `root`, returning matches in document order.
    public func evaluate(_ root: JSONValue) -> [Match] {
        var current = [Match(location: [], value: root)]
        for step in steps {
            var next: [Match] = []
            for match in current {
                if step.isRecursive {
                    Self.descendantsAndSelf(of: match) { candidate in
                        Self.apply(step.selector, to: candidate, into: &next)
                        return next.count < Self.maximumMatches
                    }
                } else {
                    Self.apply(step.selector, to: match, into: &next)
                }
                if next.count >= Self.maximumMatches { break }
            }
            current = Array(next.prefix(Self.maximumMatches))
        }
        return current
    }

    /// Convenience: the first matching value.
    public func firstValue(in root: JSONValue) -> JSONValue? {
        evaluate(root).first?.value
    }

    private static func apply(_ selector: Selector, to match: Match, into results: inout [Match]) {
        switch selector {
        case .name(let name):
            if case .object(let members) = match.value, let member = members.last(where: { $0.key == name }) {
                results.append(Match(location: match.location + [.key(name)], value: member.value))
            }
        case .index(let index):
            if case .array(let elements) = match.value {
                let resolved = index < 0 ? elements.count + index : index
                if elements.indices.contains(resolved) {
                    results.append(Match(location: match.location + [.index(resolved)], value: elements[resolved]))
                }
            }
        case .slice(let start, let end):
            if case .array(let elements) = match.value {
                let count = elements.count
                func normalize(_ value: Int?, default fallback: Int) -> Int {
                    guard let value else { return fallback }
                    return value < 0 ? max(count + value, 0) : min(value, count)
                }
                let lower = normalize(start, default: 0)
                let upper = normalize(end, default: count)
                if lower < upper {
                    for index in lower..<upper {
                        results.append(Match(location: match.location + [.index(index)], value: elements[index]))
                    }
                }
            }
        case .wildcard:
            switch match.value {
            case .object(let members):
                for member in members {
                    results.append(Match(location: match.location + [.key(member.key)], value: member.value))
                }
            case .array(let elements):
                for (index, element) in elements.enumerated() {
                    results.append(Match(location: match.location + [.index(index)], value: element))
                }
            default:
                break
            }
        case .union(let selectors):
            for selector in selectors { apply(selector, to: match, into: &results) }
        }
    }

    /// Visits `match` and all its descendants depth-first in document order; stops when `visit` returns false.
    /// Iterative (explicit stack) so deep documents can't overflow the thread stack.
    private static func descendantsAndSelf(of match: Match, visit: (Match) -> Bool) {
        var stack = [match]
        while let current = stack.popLast() {
            guard visit(current) else { return }
            switch current.value {
            case .object(let members):
                for member in members.reversed() {
                    stack.append(Match(location: current.location + [.key(member.key)], value: member.value))
                }
            case .array(let elements):
                for (index, element) in elements.enumerated().reversed() {
                    stack.append(Match(location: current.location + [.index(index)], value: element))
                }
            default:
                break
            }
        }
    }

    /// Formats a location as a normalized path (`$['a'][0]` style uses dot form when possible: `$.a[0]`).
    public static func format(_ location: [Segment]) -> String {
        var result = "$"
        for segment in location {
            switch segment {
            case .key(let key):
                if BruExpression.isIdentifier(key) {
                    result += ".\(key)"
                } else {
                    result +=
                        "['\(key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))']"
                }
            case .index(let index):
                result += "[\(index)]"
            }
        }
        return result
    }
}

private struct JSONPathParser {
    let text: [Unicode.Scalar]
    var index = 0

    init(text: [Unicode.Scalar]) {
        self.text = text
    }

    var current: Unicode.Scalar? { index < text.count ? text[index] : nil }

    mutating func parse() throws(CoreError) -> [JSONPath.Step] {
        guard current == "$" else { throw .invalidJSONPath(reason: "A path must start with $") }
        index += 1
        var steps: [JSONPath.Step] = []
        while let character = current {
            switch character {
            case ".":
                index += 1
                var recursive = false
                if current == "." {
                    recursive = true
                    index += 1
                }
                if current == "[" {
                    guard recursive else { throw .invalidJSONPath(reason: "Unexpected '[' after '.'") }
                    steps.append(JSONPath.Step(selector: try parseBracket(), isRecursive: true))
                } else if current == "*" {
                    index += 1
                    steps.append(JSONPath.Step(selector: .wildcard, isRecursive: recursive))
                } else {
                    let name = parseDotName()
                    guard !name.isEmpty else { throw .invalidJSONPath(reason: "Expected a name after '.'") }
                    steps.append(JSONPath.Step(selector: .name(name), isRecursive: recursive))
                }
            case "[":
                steps.append(JSONPath.Step(selector: try parseBracket(), isRecursive: false))
            case " ", "\t":
                index += 1
            default:
                throw .invalidJSONPath(reason: "Unexpected character '\(character)'")
            }
        }
        return steps
    }

    mutating func parseDotName() -> String {
        var name = String.UnicodeScalarView()
        while let character = current, character != ".", character != "[", character != " " {
            name.append(character)
            index += 1
        }
        return String(name)
    }

    mutating func parseBracket() throws(CoreError) -> JSONPath.Selector {
        index += 1
        var selectors: [JSONPath.Selector] = []
        while true {
            skipSpaces()
            guard let character = current else { throw .invalidJSONPath(reason: "Missing ']'") }
            switch character {
            case "*":
                index += 1
                selectors.append(.wildcard)
            case "'", "\"":
                selectors.append(.name(try parseQuoted(character)))
            case "?":
                throw .invalidJSONPath(reason: "Filter expressions are not supported")
            default:
                selectors.append(try parseIndexOrSlice())
            }
            skipSpaces()
            if current == "," {
                index += 1
                continue
            }
            guard current == "]" else { throw .invalidJSONPath(reason: "Expected ']'") }
            index += 1
            return selectors.count == 1 ? selectors[0] : .union(selectors)
        }
    }

    mutating func skipSpaces() {
        while current == " " || current == "\t" { index += 1 }
    }

    mutating func parseQuoted(_ quote: Unicode.Scalar) throws(CoreError) -> String {
        index += 1
        var value = String.UnicodeScalarView()
        while let character = current {
            index += 1
            if character == quote { return String(value) }
            if character == "\\" {
                guard let escaped = current else { break }
                index += 1
                switch escaped {
                case "n": value.append("\n")
                case "t": value.append("\t")
                default: value.append(escaped)
                }
            } else {
                value.append(character)
            }
        }
        throw .invalidJSONPath(reason: "Unterminated quoted name")
    }

    mutating func parseIndexOrSlice() throws(CoreError) -> JSONPath.Selector {
        let start = parseInteger()
        skipSpaces()
        if current == ":" {
            index += 1
            skipSpaces()
            let end = parseInteger()
            skipSpaces()
            if current == ":" { throw .invalidJSONPath(reason: "Slice steps are not supported") }
            return .slice(start: start, end: end)
        }
        guard let start else { throw .invalidJSONPath(reason: "Expected an index, name or '*'") }
        return .index(start)
    }

    mutating func parseInteger() -> Int? {
        var digits = ""
        if current == "-" {
            digits.append("-")
            index += 1
        }
        while let character = current, ("0"..."9").contains(character), digits.count < 12 {
            digits.unicodeScalars.append(character)
            index += 1
        }
        return Int(digits)
    }
}
