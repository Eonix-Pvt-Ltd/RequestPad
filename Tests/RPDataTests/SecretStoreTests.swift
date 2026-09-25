import Foundation
import RPCore
import Testing

@testable import RPData

@Suite("SecretStore", .serialized)
struct SecretStoreTests {
    /// Unsigned macOS test runners can't use the data-protection keychain; the app does (see app-hosted tests).
    static var usesDataProtection: Bool {
        #if os(macOS)
            false
        #else
            true
        #endif
    }

    @Test func keychainRoundTripUpdateDeleteAndDeleteAll() async throws {
        let store = KeychainStore(
            service: "lk.eonix.RequestPad.tests.\(UUID().uuidString)",
            useDataProtectionKeychain: Self.usesDataProtection)
        defer { Task { try? await store.deleteAll() } }
        let token = SecretRef(account: "env:k:token")
        let other = SecretRef(account: "env:k:other")
        #expect(try await store.secret(for: token) == nil)
        try await store.setSecret("s3cr3t ✓", for: token)
        #expect(try await store.secret(for: token) == "s3cr3t ✓")
        try await store.setSecret("rotated", for: token)
        #expect(try await store.secret(for: token) == "rotated")
        try await store.setSecret("", for: other)
        #expect(try await store.secret(for: other) == "")
        #expect(try await store.accounts() == ["env:k:other", "env:k:token"])

        let snapshot = try await store.snapshot(for: [token, token, other, SecretRef(account: "missing")])
        #expect(snapshot.value(for: token) == "rotated")
        #expect(snapshot.resolver(other) == "")
        #expect(snapshot.value(for: SecretRef(account: "missing")) == nil)

        try await store.deleteSecret(for: token)
        try await store.deleteSecret(for: token)
        #expect(try await store.secret(for: token) == nil)
        try await store.deleteAll()
        #expect(try await store.accounts().isEmpty)
        try await store.deleteAll()
    }

    @Test func servicesAreIsolated() async throws {
        let first = KeychainStore(
            service: "lk.eonix.RequestPad.tests.a.\(UUID().uuidString)",
            useDataProtectionKeychain: Self.usesDataProtection)
        let second = KeychainStore(
            service: "lk.eonix.RequestPad.tests.b.\(UUID().uuidString)",
            useDataProtectionKeychain: Self.usesDataProtection)
        let reference = SecretRef(account: "same")
        try await first.setSecret("one", for: reference)
        try await second.setSecret("two", for: reference)
        #expect(try await first.secret(for: reference) == "one")
        try await first.deleteAll()
        #expect(try await second.secret(for: reference) == "two")
        try await second.deleteAll()
    }

    @Test func inMemoryStoreAndInterpolation() async throws {
        let reference = SecretRef(account: "a")
        let store = InMemorySecretStore()
        await store.setSecret("v", for: reference)
        let snapshot = try await store.snapshot(for: [reference])
        let interpolator = Interpolator(secretResolver: snapshot.resolver)
        let context = VariableContext(scopes: [VariableScope(kind: .environment, values: ["t": .secret(reference)])])
        #expect(interpolator.interpolate("{{t}}", in: context).text == "v")
        await store.deleteSecret(for: reference)
        #expect(await store.count == 0)
        await store.setSecret("x", for: reference)
        await store.deleteAll()
        #expect(await store.count == 0)
    }

    @Test func fakeAuthenticator() async throws {
        let authenticator = FakeAuthenticator()
        try await authenticator.authenticate(reason: "Reveal token")
        await authenticator.setShouldSucceed(false)
        await #expect(throws: DataError.authenticationFailed(reason: "denied")) {
            try await authenticator.authenticate(reason: "again")
        }
        #expect(await authenticator.prompts == ["Reveal token", "again"])
    }
}
