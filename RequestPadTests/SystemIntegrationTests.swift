import Foundation
import RPCore
import RPData
import RPServices
import RPStore
import SwiftUI
import Testing

@testable import RequestPad

#if os(macOS)
    import AppKit
    import ServiceManagement
#endif

/// A collection with one request and two environments, installed as the runtime's app (intents and handlers use it).
@MainActor
private func makeInstalledApp(
    isPro: Bool, client: FakeHTTPClient = FakeHTTPClient(json: #"{"ok":true}"#), install: Bool = true
) async throws
    -> (AppModel, RequestReference)
{
    let app = try TestApp.make(isPro: isPro, client: client)
    await app.load()
    let collectionID = try #require(await app.createCollection(named: "API"))
    let reference = try #require(
        await app.createRequest(
            in: collectionID, folderKey: nil, request: RequestItem(name: "Status", url: "https://{{host}}/status")))
    _ = await app.saveEnvironment(
        Environment(name: "Staging", variables: [.plain("host", "staging.example.com")]), key: nil, in: collectionID,
        secretValues: [:])
    _ = await app.saveEnvironment(
        Environment(name: "Production", variables: [.plain("host", "api.example.com")]), key: nil, in: collectionID,
        secretValues: [:])
    let staging = try #require(app.environments(for: collectionID).first { $0.environment.name == "Staging" })
    app.setActiveEnvironment(staging.key, for: collectionID)
    // Only the serialized Shortcuts suite installs into the shared runtime; parallel suites must not.
    if install { AppRuntime.shared.install(app) }
    return (app, reference)
}

@MainActor
@Suite("Shortcuts: Send Request", .serialized)
struct SendRequestIntentTests {
    @Test func proSendsAndReturnsStatusTimeAndBody() async throws {
        defer { AppRuntime.shared.install(nil) }
        let client = FakeHTTPClient(json: #"{"ok":true}"#)
        let (_, reference) = try await makeInstalledApp(isPro: true, client: client)
        let entity = try #require(try await RequestEntityQuery.all().first)
        #expect(entity.reference == reference)
        let response = try await SendRequestIntent.send(request: entity, environment: nil)
        #expect(response.statusCode == 200)
        #expect(response.body == #"{"ok":true}"#)
        #expect(response.summary.hasPrefix("200"))
        #expect(await client.requests.first?.url.host() == "staging.example.com")
    }

    @Test func chosenEnvironmentOverridesTheActiveOne() async throws {
        defer { AppRuntime.shared.install(nil) }
        let client = FakeHTTPClient(json: "{}")
        _ = try await makeInstalledApp(isPro: true, client: client)
        let request = try #require(try await RequestEntityQuery.all().first)
        let production = try #require(try await EnvironmentEntityQuery.all().first { $0.name == "Production" })
        _ = try await SendRequestIntent.send(request: request, environment: production)
        #expect(await client.requests.first?.url.host() == "api.example.com")
    }

    @Test func freeTierGetsAClearProError() async throws {
        defer { AppRuntime.shared.install(nil) }
        _ = try await makeInstalledApp(isPro: false)
        let request = try #require(try await RequestEntityQuery.all().first)
        await #expect(throws: IntentFailure.proRequired) {
            _ = try await SendRequestIntent.send(request: request, environment: nil)
        }
        #expect(String(localized: IntentFailure.proRequired.localizedStringResource).contains("Pro"))
    }

    @Test func deletedRequestAndForeignEnvironmentAreReported() async throws {
        defer { AppRuntime.shared.install(nil) }
        let (app, reference) = try await makeInstalledApp(isPro: true)
        let request = try #require(try await RequestEntityQuery.all().first)
        let otherCollection = try #require(await app.createCollection(named: "Other"))
        _ = await app.saveEnvironment(Environment(name: "Elsewhere"), key: nil, in: otherCollection, secretValues: [:])
        let foreign = try #require(try await EnvironmentEntityQuery.all().first { $0.name == "Elsewhere" })
        await #expect(throws: IntentFailure.environmentMismatch) {
            _ = try await SendRequestIntent.send(request: request, environment: foreign)
        }
        await app.deleteRequest(reference)
        await #expect(throws: IntentFailure.requestNotFound) {
            _ = try await SendRequestIntent.send(request: request, environment: nil)
        }
    }

    @Test func entityQueriesFindRequests() async throws {
        defer { AppRuntime.shared.install(nil) }
        _ = try await makeInstalledApp(isPro: true)
        let query = RequestEntityQuery()
        let suggested = try await query.suggestedEntities()
        #expect(suggested.map(\.name) == ["Status"])
        #expect(try await query.entities(for: suggested.map(\.id)).map(\.id) == suggested.map(\.id))
        #expect(try await query.entities(matching: "stat").count == 1)
        #expect(try await query.entities(matching: "API").count == 1)
        #expect(try await query.entities(matching: "nothing").isEmpty)
        #expect(
            try await EnvironmentEntityQuery().suggestedEntities().map(\.name).sorted() == ["Production", "Staging"])
    }

    @Test func identifiersRoundTrip() throws {
        let id = UUID()
        let joined = EntityIdentifier.join(id, "Users/List|v2.bru")
        let split = try #require(EntityIdentifier.split(joined))
        #expect(split.collectionID == id)
        #expect(split.key == "Users/List|v2.bru")
        #expect(EntityIdentifier.split("not-a-uuid|key") == nil)
        #expect(EntityIdentifier.split("\(id.uuidString)|") == nil)
    }
}

#if os(macOS)
    @MainActor
    @Suite("macOS integrations", .serialized)
    struct MacIntegrationTests {
        private func callService(_ provider: ServicesProvider, with text: String) -> String? {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("RequestPadTests-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            var message: NSString?
            withUnsafeMutablePointer(to: &message) { pointer in
                provider.sendURL(pasteboard, userData: nil, error: AutoreleasingUnsafeMutablePointer(pointer))
            }
            return message as String?
        }

        @Test func servicesOpenTheSelectedURLAsANewRequest() {
            let provider = ServicesProvider()
            var opened: [RequestItem] = []
            provider.open = { opened.append($0) }
            #expect(callService(provider, with: "  https://api.example.com/users \n") == nil)
            #expect(opened.map(\.url) == ["https://api.example.com/users"])
            #expect(opened.first?.name == "api.example.com")
            #expect(callService(provider, with: "file:///etc/hosts") != nil)
            #expect(opened.count == 1)
        }

        @Test func servicesAreDeclaredForTheProvider() throws {
            let services = try #require(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
            let entry = try #require(services.first)
            #expect(entry["NSMessage"] as? String == "sendURL")
            #expect((entry["NSMenuItem"] as? [String: String])?["default"] == "Send URL with RequestPad")
            let selector = #selector(ServicesProvider.sendURL(_:userData:error:))
            #expect(NSStringFromSelector(selector) == "sendURL:userData:error:")
            #expect(ServicesProvider().responds(to: selector))
        }

        @Test func openRequestsReachTheApp() async throws {
            let app = try TestApp.make()
            let item = RequestItem(name: "x", url: "https://x.example")
            AppRuntime.shared.show(.scratch(item), in: app)
            #expect(app.requestedOpen == .scratch(item))
        }

        @Test func loginItemFollowsTheSystemStatus() {
            let fake = FakeLoginItem()
            let model = LoginItemModel(service: fake)
            #expect(!model.isEnabled)
            model.setEnabled(true)
            #expect(fake.registerCalls == 1)
            #expect(model.isEnabled)
            fake.status = .requiresApproval
            model.refresh()
            #expect(model.needsApproval && model.isEnabled)
            model.setEnabled(false)
            #expect(fake.unregisterCalls == 1)
            #expect(!model.isEnabled)
            fake.failure = true
            model.setEnabled(true)
            #expect(model.errorMessage?.isEmpty == false)
            #expect(!model.isEnabled)
        }

        @Test func quickSendSendsATypedURL() async throws {
            let app = try TestApp.make(isPro: true, client: FakeHTTPClient(json: #"{"up":true}"#))
            await app.load()
            let model = QuickSendModel(app: app)
            model.urlText = "not a url"
            #expect(!model.canSend)
            model.urlText = "status.example.com/health"
            #expect(model.canSend)
            model.send()
            for _ in 0..<200 where model.state == .sending { try await Task.sleep(for: .milliseconds(10)) }
            guard case .finished(let result) = model.state else {
                Issue.record("Expected a result, got \(model.state)")
                return
            }
            #expect(result.statusCode == 200)
            #expect(result.bodyPreview == #"{"up":true}"#)
            #expect(!result.isTruncated)
            model.openInApp()
            #expect(app.requestedOpen != nil)
        }

        @Test func quickSendCapsTheBodyAt64KB() async throws {
            let large = "\"" + String(repeating: "x", count: 100_000) + "\""
            let app = try TestApp.make(isPro: true, client: FakeHTTPClient(json: large))
            await app.load()
            let model = QuickSendModel(app: app)
            model.urlText = "https://big.example.com"
            model.send()
            for _ in 0..<200 where model.state == .sending { try await Task.sleep(for: .milliseconds(10)) }
            guard case .finished(let result) = model.state else {
                Issue.record("Expected a result, got \(model.state)")
                return
            }
            #expect(result.bodyPreview.utf8.count == QuickSendModel.previewBytes)
            #expect(result.isTruncated)
        }

        @Test func quickSendUsesTheChosenEnvironment() async throws {
            let client = FakeHTTPClient(json: "{}")
            let (app, reference) = try await makeInstalledApp(isPro: true, client: client, install: false)
            let model = QuickSendModel(app: app)
            let saved = try #require(model.savedRequests.first { $0.reference == reference })
            model.source = .saved(saved.id)
            let production = try #require(
                app.environments(for: reference.collectionID).first { $0.environment.name == "Production" })
            model.environment = .key(production.key)
            model.send()
            for _ in 0..<200 where model.state == .sending { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await client.requests.first?.url.host() == "api.example.com")
            model.openInApp()
            #expect(app.requestedOpen == .request(reference))
        }

        /// P09.2 proxy: the popover's content renders well under 100 ms with 300 saved requests.
        @Test func quickSendRendersQuickly() async throws {
            let app = try TestApp.make(isPro: true)
            await app.load()
            let collectionID = try #require(await app.createCollection(named: "Big"))
            for index in 0..<300 {
                _ = try await app.environment.store.upsertRequest(
                    RequestItem(name: "Request \(index)", url: "https://example.com/\(index)", sortOrder: index),
                    folderID: nil,
                    in: collectionID)
            }
            await app.reloadTree(collectionID)
            #expect(app.savedRequests().count == 300)
            _ = ImageRenderer(content: QuickSendView(app: app)).nsImage
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                for _ in 0..<5 { _ = ImageRenderer(content: QuickSendView(app: app)).nsImage }
            }
            #expect(elapsed / 5 < .milliseconds(100), "Average render \(elapsed / 5)")
        }
    }

    /// Records login item calls; never touches the real login items.
    private final class FakeLoginItem: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var failure = false
        var registerCalls = 0
        var unregisterCalls = 0

        func register() throws {
            registerCalls += 1
            if failure { throw CocoaError(.featureUnsupported) }
            status = .enabled
        }

        func unregister() throws {
            unregisterCalls += 1
            if failure { throw CocoaError(.featureUnsupported) }
            status = .notRegistered
        }

        func openSystemSettings() {}
    }
#endif
