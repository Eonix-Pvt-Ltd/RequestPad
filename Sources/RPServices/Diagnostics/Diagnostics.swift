import Foundation
import MetricKit
import OSLog
import RPCore
import RPData

/// Builds the "Export Diagnostics" text (X04.3): app/OS/device, non-sensitive settings, data counts, recent
/// RequestPad log lines (already privacy-redacted by `os.Logger`, plus URL redaction) and MetricKit summaries.
/// Never includes secrets, bodies, header values, or file contents.
public struct DiagnosticsReport: Sendable {
    public struct Environment: Sendable {
        public var appVersion: String
        public var build: String
        public var osVersion: String
        public var deviceModel: String
        public var locale: String

        public static func current(bundle: Bundle = .main) -> Environment {
            Environment(
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString, deviceModel: Self.hardwareModel(),
                locale: Locale.current.identifier)
        }

        static func hardwareModel() -> String {
            #if os(macOS)
                let key = "hw.model"
            #else
                let key = "hw.machine"
            #endif
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown" }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    public var environment: Environment
    public var settings: [String: String]
    public var counts: [String: Int]
    public var logLines: [String]
    public var metricPayloads: [String]
    public var generatedAt: Date

    public var text: String {
        var lines = ["RequestPad diagnostics", "Generated: \(generatedAt.formatted(.iso8601))", ""]
        lines += [
            "App: \(environment.appVersion) (\(environment.build))", "OS: \(environment.osVersion)",
            "Device: \(environment.deviceModel)",
            "Locale: \(environment.locale)", "", "Settings:",
        ]
        lines += settings.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
        lines += ["", "Data:"] + counts.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
        lines += ["", "MetricKit payloads (\(metricPayloads.count)):"] + metricPayloads.map { "  \($0)" }
        lines += ["", "Recent log (\(logLines.count) lines):"] + logLines.map { "  \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Replaces every URL with scheme and host (query strings and paths can carry identifiers or tokens).
    public static func redactURLs(in text: String) -> String {
        guard let detector = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+"#) else {
            return text
        }
        var output = text
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])) else { continue }
            output.replaceSubrange(range, with: Log.redacted(url))
        }
        return output
    }
}

public struct DiagnosticsService: Sendable {
    public static let maximumLogLines = 500
    let store: LocalStore
    let preferences: Preferences
    let locations: StorageLocations

    public init(store: LocalStore, preferences: Preferences, locations: StorageLocations) {
        self.store = store
        self.preferences = preferences
        self.locations = locations
    }

    public func makeReport(now: Date = Date(), bundle: Bundle = .main) async -> DiagnosticsReport {
        let settings: [String: String] = [
            "defaultTimeoutSeconds": String(preferences.defaultTimeoutSeconds),
            "followRedirects": String(preferences.followRedirects),
            "localEchoEnabled": String(preferences.localEchoEnabled),
            "menuBarQuickSendEnabled": String(preferences.menuBarQuickSendEnabled),
            "appearance": preferences.appearance.rawValue,
        ]
        let counts = (try? await store.rowCounts()) ?? [:]
        return DiagnosticsReport(
            environment: .current(bundle: bundle), settings: settings, counts: counts,
            logLines: Self.recentLogLines(since: now.addingTimeInterval(-3600)),
            metricPayloads: MetricsSubscriber.payloadSummaries(in: locations.diagnosticsDirectory), generatedAt: now)
    }

    /// RequestPad's own log entries from this process (dynamic values are `<private>` unless marked public).
    static func recentLogLines(since date: Date) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = store.position(date: date)
        guard
            let entries = try? store.getEntries(
                at: position, matching: NSPredicate(format: "subsystem == %@", AppConstants.loggingSubsystem))
        else { return [] }
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append(
                "\(entry.date.formatted(.iso8601)) [\(entry.category)] \(DiagnosticsReport.redactURLs(in: entry.composedMessage))"
            )
        }
        return Array(lines.suffix(maximumLogLines))
    }
}

/// Receives MetricKit payloads from launch and keeps the last ``maximumStoredPayloads`` on disk (B1).
public final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    // @unchecked: only immutable state; file writes are independent per payload.
    public static let maximumStoredPayloads = 30
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        super.init()
    }

    public func start() { MXMetricManager.shared.add(self) }
    public func stop() { MXMetricManager.shared.remove(self) }

    #if os(iOS)
        public func didReceive(_ payloads: [MXMetricPayload]) {
            for payload in payloads { store(payload.jsonRepresentation(), kind: "metrics") }
        }
    #endif

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { store(payload.jsonRepresentation(), kind: "diagnostics") }
    }

    func store(_ data: Data, kind: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(kind)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        try? data.write(to: directory.appending(path: name), options: .atomic)
        Self.prune(directory)
    }

    static func files(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func prune(_ directory: URL) {
        let all = files(in: directory)
        for url in all.dropLast(maximumStoredPayloads) { try? FileManager.default.removeItem(at: url) }
    }

    /// One line per stored payload: name and size (contents stay on disk until the user shares them).
    public static func payloadSummaries(in directory: URL) -> [String] {
        files(in: directory).map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return
                "\(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
        }
    }
}

/// Small policies used by the UI.
public enum AppPolicies {
    /// Show the Local Network explainer before the first request to a LAN host on iOS (F01.9).
    public static func needsLocalNetworkExplainer(for url: URL, preferences: Preferences) -> Bool {
        #if os(iOS)
            guard let host = url.host(percentEncoded: false) else { return false }
            return LocalAddress.isLocal(host: host) && !LocalAddress.isLoopback(host: host)
                && !preferences.localNetworkExplainerShown
        #else
            return false
        #endif
    }

    public static let successfulRequestsBeforeReview = 5

    /// Ask for a review after the 5th successful request, at most once per app version, never on launch (X02.3).
    public static func shouldRequestReview(preferences: Preferences, appVersion: String) -> Bool {
        preferences.successfulRequestCount >= successfulRequestsBeforeReview
            && preferences.lastReviewPromptVersion != appVersion
    }
}
