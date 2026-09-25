import Foundation
import LocalAuthentication
import RPCore
import Security

/// Storage for secret values (F04.4, B5). Values never leave the device and are never logged.
public protocol SecretStore: Sendable {
    func secret(for reference: SecretRef) async throws(DataError) -> String?
    func setSecret(_ value: String, for reference: SecretRef) async throws(DataError)
    func deleteSecret(for reference: SecretRef) async throws(DataError)
    /// Removes every secret RequestPad stored (Erase All Data, X04.2).
    func deleteAll() async throws(DataError)
}

extension SecretStore {
    /// Reads every referenced secret in one pass so synchronous code (the interpolator) can use them.
    public func snapshot(for references: some Sequence<SecretRef>) async throws(DataError) -> SecretSnapshot {
        var values: [SecretRef: String] = [:]
        for reference in Set(references) {
            if let value = try await secret(for: reference) { values[reference] = value }
        }
        return SecretSnapshot(values: values)
    }
}

/// Secret values fetched ahead of a send. Deliberately not `CustomStringConvertible`/`Codable`.
public struct SecretSnapshot: Sendable {
    private let values: [SecretRef: String]

    public init(values: [SecretRef: String] = [:]) {
        self.values = values
    }

    public func value(for reference: SecretRef) -> String? { values[reference] }

    /// A resolver for ``RPCore/Interpolator``.
    public var resolver: @Sendable (SecretRef) -> String? {
        let values = values
        return { values[$0] }
    }
}

/// Keychain-backed ``SecretStore``: `kSecClassGenericPassword`, service = bundle identifier, accessible after
/// first unlock on this device only, never synchronized (B5; no Part A item syncs, ADR-0031).
public actor KeychainStore: SecretStore {
    public let service: String
    private let useDataProtectionKeychain: Bool

    /// - Parameter useDataProtectionKeychain: `true` in the app (iOS-style keychain on macOS, requires signing);
    ///   unsigned macOS test runners use the legacy file keychain instead.
    public init(service: String = AppConstants.keychainService, useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    public func secret(for reference: SecretRef) throws(DataError) -> String? {
        var query = baseQuery(account: reference.account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw .keychain(status: errSecDecode, operation: "read")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status: status, operation: "read")
        }
    }

    public func setSecret(_ value: String, for reference: SecretRef) throws(DataError) {
        let data = Data(value.utf8)
        let query = baseQuery(account: reference.account)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw .keychain(status: updateStatus, operation: "update") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw .keychain(status: addStatus, operation: "save") }
    }

    public func deleteSecret(for reference: SecretRef) throws(DataError) {
        let status = SecItemDelete(baseQuery(account: reference.account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(status: status, operation: "delete")
        }
    }

    public func deleteAll() throws(DataError) {
        // The legacy macOS keychain deletes one match per call; loop until nothing matches.
        for _ in 0..<10_000 {
            let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw .keychain(status: status, operation: "delete") }
            if useDataProtectionKeychain { return }
        }
    }

    /// Accounts currently stored (diagnostics counts and tests; never values).
    public func accounts() throws(DataError) -> [String] {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw .keychain(status: status, operation: "list")
        }
    }
}

/// In-memory ``SecretStore`` for tests and previews.
public actor InMemorySecretStore: SecretStore {
    private var values: [SecretRef: String]

    public init(values: [SecretRef: String] = [:]) {
        self.values = values
    }

    public func secret(for reference: SecretRef) -> String? { values[reference] }
    public func setSecret(_ value: String, for reference: SecretRef) { values[reference] = value }
    public func deleteSecret(for reference: SecretRef) { values[reference] = nil }
    public func deleteAll() { values.removeAll() }
    public var count: Int { values.count }
}

/// Asks the user to authenticate before a secret is revealed in the UI (F04.5).
public protocol UserAuthenticator: Sendable {
    func authenticate(reason: String) async throws(DataError)
}

/// Face ID / Touch ID / device passcode via LocalAuthentication. Devices without a passcode reveal without a
/// prompt (nothing to authenticate against).
public struct DeviceOwnerAuthenticator: UserAuthenticator {
    public init() {}

    public func authenticate(reason: String) async throws(DataError) {
        let context = LAContext()
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            if let code = availabilityError?.code, code == LAError.passcodeNotSet.rawValue { return }
            throw .authenticationFailed(reason: availabilityError?.localizedDescription ?? "unavailable")
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard success else { throw DataError.authenticationFailed(reason: "denied") }
        } catch let error as DataError {
            throw error
        } catch {
            throw .authenticationFailed(reason: error.localizedDescription)
        }
    }
}

/// Test double: succeeds or fails as configured and counts prompts.
public actor FakeAuthenticator: UserAuthenticator {
    public var shouldSucceed: Bool
    public private(set) var prompts: [String] = []

    public init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    public func authenticate(reason: String) throws(DataError) {
        prompts.append(reason)
        guard shouldSucceed else { throw .authenticationFailed(reason: "denied") }
    }

    public func setShouldSucceed(_ value: Bool) { shouldSucceed = value }
}
