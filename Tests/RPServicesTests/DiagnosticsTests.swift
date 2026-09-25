import Foundation
import RPCore
import RPData
import Testing

@testable import RPServices

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test func redactsURLsInLogText() {
        let text =
            "GET https://api.example.com/v1/users?token=abc#x → 200; retry http://10.0.0.5:8080/admin/secret and done"
        #expect(
            DiagnosticsReport.redactURLs(in: text)
                == "GET https://api.example.com → 200; retry http://10.0.0.5:8080 and done")
        #expect(DiagnosticsReport.redactURLs(in: "no urls here") == "no urls here")
    }

    @Test func reportContainsSettingsCountsAndNoSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "diag-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StorageLocations(
            applicationSupport: root.appending(path: "support"), temporary: root.appending(path: "tmp"))
        try locations.prepare()
        let store = LocalStore(modelContainer: try PersistenceContainer.makeInMemory())
        let collection = try await store.createCollection(name: "Secretive", storage: .native)
        try await store.upsertRequest(
            RequestItem(name: "r", url: "https://h?api_key=SHOULD_NOT_APPEAR"), folderID: nil, in: collection.id)
        let defaults = try #require(UserDefaults(suiteName: "diag-\(UUID().uuidString)"))
        let preferences = Preferences(defaults: defaults)
        preferences.defaultTimeoutSeconds = 45
        let subscriber = MetricsSubscriber(directory: locations.diagnosticsDirectory)
        subscriber.store(Data("{\"a\":1}".utf8), kind: "diagnostics")
        Log.logger(.diagnostics).info("Diagnostics self-test for https://example.com/private/path?token=x")

        let report = await DiagnosticsService(store: store, preferences: preferences, locations: locations).makeReport(
            now: Date())
        let text = report.text
        #expect(text.contains("defaultTimeoutSeconds: 45"))
        #expect(text.contains("requests: 1"))
        #expect(text.contains("MetricKit payloads (1):"))
        #expect(!text.contains("SHOULD_NOT_APPEAR"))
        #expect(!text.contains("Secretive"))
        #expect(!text.contains("token=x"))
        #expect(report.environment.deviceModel != "unknown")
        #expect(DiagnosticsReport.Environment.current().osVersion.isEmpty == false)
    }

    @Test func metricPayloadsArePrunedToLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "metrics-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let subscriber = MetricsSubscriber(directory: directory)
        for index in 0..<(MetricsSubscriber.maximumStoredPayloads + 5) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appending(path: String(format: "diagnostics-%05d.json", index)))
        }
        subscriber.store(Data("{}".utf8), kind: "diagnostics")
        #expect(MetricsSubscriber.payloadSummaries(in: directory).count == MetricsSubscriber.maximumStoredPayloads)
        subscriber.start()
        subscriber.stop()
    }

    @Test func policies() throws {
        let defaults = try #require(UserDefaults(suiteName: "policy-\(UUID().uuidString)"))
        let preferences = Preferences(defaults: defaults)
        let lan = try #require(URL(string: "http://192.168.1.20:8080/api"))
        let loopback = try #require(URL(string: "http://127.0.0.1:8080"))
        let internet = try #require(URL(string: "https://example.com"))
        #if os(iOS)
            #expect(AppPolicies.needsLocalNetworkExplainer(for: lan, preferences: preferences))
            preferences.localNetworkExplainerShown = true
            #expect(!AppPolicies.needsLocalNetworkExplainer(for: lan, preferences: preferences))
        #else
            #expect(!AppPolicies.needsLocalNetworkExplainer(for: lan, preferences: preferences))
        #endif
        #expect(
            !AppPolicies.needsLocalNetworkExplainer(
                for: loopback,
                preferences: Preferences(defaults: try #require(UserDefaults(suiteName: "p2-\(UUID().uuidString)")))))
        #expect(!AppPolicies.needsLocalNetworkExplainer(for: internet, preferences: preferences))

        #expect(!AppPolicies.shouldRequestReview(preferences: preferences, appVersion: "1.0.0"))
        preferences.successfulRequestCount = 5
        #expect(AppPolicies.shouldRequestReview(preferences: preferences, appVersion: "1.0.0"))
        preferences.lastReviewPromptVersion = "1.0.0"
        #expect(!AppPolicies.shouldRequestReview(preferences: preferences, appVersion: "1.0.0"))
        #expect(AppPolicies.shouldRequestReview(preferences: preferences, appVersion: "1.1.0"))
    }
}
