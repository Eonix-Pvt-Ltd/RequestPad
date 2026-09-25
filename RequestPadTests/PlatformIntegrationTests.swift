import Foundation
import RPCore
import RPData
import RPServices
import Testing

/// Runs inside the signed, sandboxed app (host), so App Transport Security, entitlements and the Keychain
/// behave exactly as in production (ADR-0010, B7).
@Suite("PlatformIntegration", .serialized)
struct PlatformIntegrationTests {
    func send(_ url: String, timeoutMilliseconds: Int = 3_000) async -> Result<HTTPResponse, ServiceError> {
        var request = RequestItem(name: "probe", url: url)
        request.settings.timeoutMilliseconds = timeoutMilliseconds
        guard
            let resolved = try? RequestResolver(interpolator: Interpolator()).resolve(
                request, context: ResolutionContext())
        else {
            return .failure(.notFound("request"))
        }
        do {
            return .success(
                try await URLSessionHTTPClient().send(resolved, files: PathFileResolver(baseDirectory: nil)))
        } catch {
            return .failure(error)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func plainHTTPToLoopbackIsAllowedAndLocalEchoRunsInSandbox() async throws {
        let server = LocalEchoServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let result = await send("http://127.0.0.1:\(port)/status/204")
        #expect((try? result.get().statusCode) == 204, "\(result.map(\.statusCode))")
        let named = await send("http://localhost:\(port)/status/200")
        #expect((try? named.get().statusCode) == 200)
    }

    @Test(.timeLimit(.minutes(1)))
    func plainHTTPToPublicHostIsBlockedByATS() async {
        let result = await send("http://example.com/")
        guard case .failure(let error) = result else {
            Issue.record("Expected ATS to block plain HTTP to a public host")
            return
        }
        #expect(error == .appTransportSecurity(host: "example.com"))
    }

    @Test(.timeLimit(.minutes(1)))
    func plainHTTPToPrivateAddressIsNotBlockedByATS() async {
        // 10.255.255.1 is in the 10.0.0.0/8 exception; nothing answers there, so the request times out or fails to
        // connect — but it must not be rejected by ATS.
        let result = await send("http://10.255.255.1:9/", timeoutMilliseconds: 1_500)
        if case .failure(let error) = result {
            #expect(error != .appTransportSecurity(host: "10.255.255.1"))
        }
    }

    @Test func dataProtectionKeychainWorksInSignedApp() async throws {
        let store = KeychainStore(
            service: "lk.eonix.RequestPad.apphost.\(UUID().uuidString)", useDataProtectionKeychain: true)
        let reference = SecretRef(account: "probe")
        try await store.setSecret("value", for: reference)
        #expect(try await store.secret(for: reference) == "value")
        try await store.deleteAll()
        #expect(try await store.secret(for: reference) == nil)
    }

    @Test func securityScopedBookmarksWorkInSandbox() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "bookmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let access = SecurityScopedBookmarks()
        let bookmark = try access.makeBookmark(for: folder)
        let resolved = try access.resolve(bookmark)
        #expect(
            resolved.url.standardizedFileURL.path(percentEncoded: false)
                == folder.standardizedFileURL.path(percentEncoded: false))
        let token = access.beginAccess(to: resolved.url)
        #expect(FileManager.default.isReadableFile(atPath: resolved.url.path(percentEncoded: false)))
        token.stop()
    }
}
