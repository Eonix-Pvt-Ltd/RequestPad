import Foundation

/// Scopes in precedence order, highest first (Bruno precedence, ADR-0013).
public enum VariableScopeKind: Int, Hashable, Sendable, CaseIterable, Comparable {
    case runtime
    case request
    case folder
    case environment
    case collection
    case global

    public static func < (lhs: VariableScopeKind, rhs: VariableScopeKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct VariableScope: Hashable, Sendable {
    public var kind: VariableScopeKind
    public var values: [String: VariableValue]

    public init(kind: VariableScopeKind, values: [String: VariableValue]) {
        self.kind = kind
        self.values = values
    }

    /// Builds a scope from enabled variables; later duplicates win.
    public init(kind: VariableScopeKind, variables: [Variable]) {
        var values: [String: VariableValue] = [:]
        for variable in variables where variable.isEnabled && !variable.name.isEmpty {
            values[variable.name] = variable.value
        }
        self.init(kind: kind, values: values)
    }

    /// Builds a scope from `.bru`-style key/value rows (request and folder vars). Bruno's `@name` (local
    /// variable) prefix is not part of the name.
    public init(kind: VariableScopeKind, rows: [KeyValue]) {
        var values: [String: VariableValue] = [:]
        for row in rows.active {
            let name = row.name.hasPrefix("@") ? String(row.name.dropFirst()) : row.name
            if !name.isEmpty { values[name] = .plain(row.value) }
        }
        self.init(kind: kind, values: values)
    }
}

/// All variables visible to a request. Several scopes may share a kind (nested folders: innermost first).
public struct VariableContext: Hashable, Sendable {
    public var scopes: [VariableScope]

    public init(scopes: [VariableScope] = []) {
        self.scopes = scopes.enumerated().sorted { lhs, rhs in
            lhs.element.kind == rhs.element.kind ? lhs.offset < rhs.offset : lhs.element.kind < rhs.element.kind
        }.map(\.element)
    }

    public func lookup(_ name: String) -> (value: VariableValue, scope: VariableScopeKind)? {
        for scope in scopes {
            if let value = scope.values[name] { return (value, scope.kind) }
        }
        return nil
    }

    /// Every visible variable name with its winning scope, sorted by name (for autocomplete and the variables list).
    public var visibleNames: [(name: String, scope: VariableScopeKind)] {
        var seen: [String: VariableScopeKind] = [:]
        for scope in scopes {
            for name in scope.values.keys where seen[name] == nil { seen[name] = scope.kind }
        }
        return seen.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }
}

/// A `{{name}}` occurrence in a template.
public struct VariableToken: Hashable, Sendable {
    public var name: String
    /// Range of the whole `{{…}}` token in the template.
    public var range: Range<String.Index>
}

/// Sources of values for dynamic variables (`{{$guid}}` etc.), injectable for deterministic tests.
public struct DynamicValues: Sendable {
    public var now: @Sendable () -> Date
    public var uuid: @Sendable () -> UUID
    public var randomInt: @Sendable () -> Int

    public init(
        now: @escaping @Sendable () -> Date = { Date() }, uuid: @escaping @Sendable () -> UUID = { UUID() },
        randomInt: @escaping @Sendable () -> Int = { Int.random(in: 0...1000) }
    ) {
        self.now = now
        self.uuid = uuid
        self.randomInt = randomInt
    }

    public static let live = DynamicValues()

    func value(for name: String) -> String? {
        switch name {
        case "$guid", "$randomUUID": return uuid().uuidString.lowercased()
        case "$timestamp": return String(Int(now().timeIntervalSince1970))
        case "$isoTimestamp": return now().formatted(.iso8601)
        case "$randomInt": return String(randomInt())
        default: return nil
        }
    }
}

/// Result of interpolating a template.
public struct Interpolation: Hashable, Sendable {
    public var text: String
    /// Names that had no value; their `{{name}}` text is left in place (F04.3).
    public var unresolved: [String]
    /// Whether any secret value was substituted (callers must then treat `text` as sensitive).
    public var containsSecrets: Bool
}

/// Replaces `{{name}}` tokens using a ``VariableContext`` (F04.2–F04.4).
public struct Interpolator: Sendable {
    public enum Mode: Sendable {
        /// Real values, for sending.
        case send
        /// Secret values replaced by ``maskedSecret`` (UI previews, cURL copy by default, history, logs).
        case display
    }

    public static let maskedSecret = "••••••"
    /// Nested references deeper than this are left unresolved (protects against runaway expansion).
    public static let maximumDepth = 8
    /// Output larger than this stops expanding (protects against exponential expansion).
    public static let maximumOutputBytes = 16 * 1024 * 1024

    public var secretResolver: @Sendable (SecretRef) -> String?
    public var dynamicValues: DynamicValues

    public init(
        secretResolver: @escaping @Sendable (SecretRef) -> String? = { _ in nil },
        dynamicValues: DynamicValues = .live
    ) {
        self.secretResolver = secretResolver
        self.dynamicValues = dynamicValues
    }

    /// Finds `{{name}}` tokens. Whitespace inside the braces is ignored; empty names are not tokens.
    public static func tokens(in template: String) -> [VariableToken] {
        var tokens: [VariableToken] = []
        var searchStart = template.startIndex
        while let open = template.range(of: "{{", range: searchStart..<template.endIndex) {
            guard let close = template.range(of: "}}", range: open.upperBound..<template.endIndex) else { break }
            let inner = template[open.upperBound..<close.lowerBound]
            if inner.contains("{") {
                // `{{a {{b}}`: restart at the inner opening so the innermost token is found.
                searchStart = template.index(after: open.lowerBound)
                continue
            }
            let name = inner.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains("\n") {
                tokens.append(VariableToken(name: name, range: open.lowerBound..<close.upperBound))
            }
            searchStart = close.upperBound
        }
        return tokens
    }

    public func interpolate(_ template: String, in context: VariableContext, mode: Mode = .send) -> Interpolation {
        var state = State()
        let text = expand(template, context: context, mode: mode, depth: 0, stack: [], state: &state)
        return Interpolation(text: text, unresolved: state.unresolved, containsSecrets: state.containsSecrets)
    }

    private struct State {
        var unresolved: [String] = []
        var containsSecrets = false
        var outputBytes = 0

        mutating func markUnresolved(_ name: String) {
            if !unresolved.contains(name) { unresolved.append(name) }
        }
    }

    private func expand(
        _ template: String, context: VariableContext, mode: Mode, depth: Int, stack: Set<String>, state: inout State
    ) -> String {
        let tokens = Self.tokens(in: template)
        guard !tokens.isEmpty else { return template }
        var output = ""
        var cursor = template.startIndex
        for token in tokens {
            output += template[cursor..<token.range.lowerBound]
            cursor = token.range.upperBound
            let original = String(template[token.range])
            guard state.outputBytes <= Self.maximumOutputBytes else {
                output += original
                continue
            }
            let replacement = value(
                for: token.name, original: original, context: context, mode: mode, depth: depth, stack: stack,
                state: &state)
            state.outputBytes += replacement.utf8.count
            output += replacement
        }
        output += template[cursor...]
        return output
    }

    private func value(
        for name: String, original: String, context: VariableContext, mode: Mode, depth: Int, stack: Set<String>,
        state: inout State
    ) -> String {
        if name.hasPrefix("$"), let dynamic = dynamicValues.value(for: name) { return dynamic }
        guard let (value, _) = context.lookup(name), depth < Self.maximumDepth, !stack.contains(name) else {
            state.markUnresolved(name)
            return original
        }
        switch value {
        case .plain(let text):
            return expand(
                text, context: context, mode: mode, depth: depth + 1, stack: stack.union([name]), state: &state)
        case .secret(let reference):
            switch mode {
            case .display:
                return Self.maskedSecret
            case .send:
                guard let secret = secretResolver(reference) else {
                    state.markUnresolved(name)
                    return original
                }
                state.containsSecrets = true
                return secret
            }
        }
    }
}
