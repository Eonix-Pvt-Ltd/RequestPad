import Foundation

/// User preferences (B5: `UserDefaults`; no app group because there are no extensions, ADR-0006).
/// Every key lives under the `rp.` prefix so "Erase All Data" can remove exactly RequestPad's keys.
public final class Preferences: @unchecked Sendable {
    // @unchecked: UserDefaults is documented as thread-safe; this class holds no other mutable state.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public enum Key: String, CaseIterable, Sendable {
        case onboardingCompleted = "rp.onboardingCompleted"
        case defaultTimeoutSeconds = "rp.defaultTimeoutSeconds"
        case followRedirects = "rp.followRedirects"
        case successfulRequestCount = "rp.successfulRequestCount"
        case lastReviewPromptVersion = "rp.lastReviewPromptVersion"
        case localNetworkExplainerShown = "rp.localNetworkExplainerShown"
        case menuBarQuickSendEnabled = "rp.menuBarQuickSendEnabled"
        case localEchoEnabled = "rp.localEchoEnabled"
        case activeEnvironments = "rp.activeEnvironments"
        case lastSelection = "rp.lastSelection"
        case appearance = "rp.appearance"
    }

    public enum Appearance: String, CaseIterable, Sendable {
        case system
        case light
        case dark
    }

    public var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted.rawValue) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted.rawValue) }
    }

    /// Default request timeout in seconds (1–600, default 30; F01.6).
    public var defaultTimeoutSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Key.defaultTimeoutSeconds.rawValue)
            return stored == 0 ? 30 : min(max(stored, 1), 600)
        }
        set { defaults.set(min(max(newValue, 1), 600), forKey: Key.defaultTimeoutSeconds.rawValue) }
    }

    public var followRedirects: Bool {
        get { defaults.object(forKey: Key.followRedirects.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.followRedirects.rawValue) }
    }

    public var successfulRequestCount: Int {
        get { defaults.integer(forKey: Key.successfulRequestCount.rawValue) }
        set { defaults.set(max(newValue, 0), forKey: Key.successfulRequestCount.rawValue) }
    }

    public var lastReviewPromptVersion: String? {
        get { defaults.string(forKey: Key.lastReviewPromptVersion.rawValue) }
        set { defaults.set(newValue, forKey: Key.lastReviewPromptVersion.rawValue) }
    }

    public var localNetworkExplainerShown: Bool {
        get { defaults.bool(forKey: Key.localNetworkExplainerShown.rawValue) }
        set { defaults.set(newValue, forKey: Key.localNetworkExplainerShown.rawValue) }
    }

    public var menuBarQuickSendEnabled: Bool {
        get { defaults.bool(forKey: Key.menuBarQuickSendEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.menuBarQuickSendEnabled.rawValue) }
    }

    public var localEchoEnabled: Bool {
        get { defaults.bool(forKey: Key.localEchoEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.localEchoEnabled.rawValue) }
    }

    public var appearance: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: Key.appearance.rawValue) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance.rawValue) }
    }

    /// Active environment per collection (collection id → environment id).
    public func activeEnvironment(for collectionID: UUID) -> UUID? {
        let map = defaults.dictionary(forKey: Key.activeEnvironments.rawValue) as? [String: String] ?? [:]
        return map[collectionID.uuidString].flatMap(UUID.init(uuidString:))
    }

    public func setActiveEnvironment(_ environmentID: UUID?, for collectionID: UUID) {
        var map = defaults.dictionary(forKey: Key.activeEnvironments.rawValue) as? [String: String] ?? [:]
        map[collectionID.uuidString] = environmentID?.uuidString
        defaults.set(map, forKey: Key.activeEnvironments.rawValue)
    }

    /// Opaque state-restoration value (last selected collection/request), X01.4.
    public var lastSelection: String? {
        get { defaults.string(forKey: Key.lastSelection.rawValue) }
        set { defaults.set(newValue, forKey: Key.lastSelection.rawValue) }
    }

    /// Removes every RequestPad preference (X04.2).
    public func removeAll() {
        for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
    }
}
