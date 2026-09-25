import Foundation

/// A reference to a secret stored in the Keychain. Deliberately not `CustomStringConvertible` so it can't be
/// interpolated into text by accident; only the resolver turns it into a value.
public struct SecretRef: Hashable, Sendable, Codable {
    /// Keychain account identifier.
    public let account: String

    public init(account: String) {
        self.account = account
    }

    /// A stable account for a secret variable in an environment (F04.4).
    public static func environmentVariable(environmentKey: String, name: String) -> SecretRef {
        SecretRef(account: "env:\(environmentKey):\(name)")
    }
}

public enum VariableValue: Hashable, Sendable, Codable {
    case plain(String)
    case secret(SecretRef)

    public var isSecret: Bool {
        if case .secret = self { return true }
        return false
    }
}

/// A named variable in an environment, collection, folder or request scope (F04).
public struct Variable: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: VariableValue
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, value: VariableValue, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }

    public static func plain(_ name: String, _ value: String, isEnabled: Bool = true) -> Variable {
        Variable(name: name, value: .plain(value), isEnabled: isEnabled)
    }

    public static func == (lhs: Variable, rhs: Variable) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value && lhs.isEnabled == rhs.isEnabled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(value)
        hasher.combine(isEnabled)
    }

    /// Bruno/RequestPad variable names: letters, digits, `_`, `-`, `.`; must not be empty.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128
            && name.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "."
            }
    }
}

/// A named set of variables, e.g. "Local", "Staging" (F04.1).
public struct Environment: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var variables: [Variable]
    /// Lines of the `.bru` environment file RequestPad does not interpret (e.g. `color`, `extends`), preserved.
    public var preservedBlocks: [String]

    public init(id: UUID = UUID(), name: String, variables: [Variable] = [], preservedBlocks: [String] = []) {
        self.id = id
        self.name = name
        self.variables = variables
        self.preservedBlocks = preservedBlocks
    }
}
