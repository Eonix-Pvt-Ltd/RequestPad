import Foundation
import Observation

/// Features that need RequestPad Pro (PRD §4).
public enum ProFeature: String, CaseIterable, Sendable, Identifiable {
    case unlimitedCollections
    case folderCollections
    case openAPIImport
    case postmanImport
    case graphQL
    case oauth2
    case extractionRules
    case assertionsAndRunner
    case cookieJar
    case shortcuts
    case menuBarQuickSend
    case extendedHistory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unlimitedCollections: String(localized: "Unlimited collections and requests", bundle: .module)
        case .folderCollections: String(localized: "Git-friendly .bru folder collections", bundle: .module)
        case .openAPIImport: String(localized: "OpenAPI 3 import", bundle: .module)
        case .postmanImport: String(localized: "Postman collection import", bundle: .module)
        case .graphQL: String(localized: "GraphQL with schema autocomplete", bundle: .module)
        case .oauth2: String(localized: "OAuth 2.0 (client credentials, PKCE)", bundle: .module)
        case .extractionRules: String(localized: "Response extraction to variables", bundle: .module)
        case .assertionsAndRunner: String(localized: "Assertions and the collection runner", bundle: .module)
        case .cookieJar: String(localized: "Persistent cookie jar", bundle: .module)
        case .shortcuts: String(localized: "Shortcuts “Send Request” action", bundle: .module)
        case .menuBarQuickSend: String(localized: "Menu bar Quick Send on Mac", bundle: .module)
        case .extendedHistory: String(localized: "History of your last 1,000 requests", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .unlimitedCollections: "square.stack.3d.up"
        case .folderCollections: "folder.badge.gearshape"
        case .openAPIImport, .postmanImport: "square.and.arrow.down"
        case .graphQL: "point.3.connected.trianglepath.dotted"
        case .oauth2: "person.badge.key"
        case .extractionRules: "arrow.down.doc"
        case .assertionsAndRunner: "checkmark.seal"
        case .cookieJar: "birthday.cake"
        case .shortcuts: "square.2.layers.3d"
        case .menuBarQuickSend: "menubar.arrow.up.rectangle"
        case .extendedHistory: "clock.arrow.circlepath"
        }
    }
}

/// Why an action needs Pro (shown on the upgrade screen).
public enum GateDecision: Hashable, Sendable {
    case allowed
    case requiresPro(ProFeature)
}

/// Decides what the current tier may do (F03.2, PRD §4). Pure: the entitlement comes from ``EntitlementState``.
public struct FeatureGate: Sendable, Hashable {
    public var isPro: Bool

    public init(isPro: Bool) {
        self.isPro = isPro
    }

    public func check(_ feature: ProFeature) -> GateDecision {
        isPro ? .allowed : .requiresPro(feature)
    }

    /// Creating a native collection when `existingCount` non-sample collections exist (sample is exempt, ADR-0009).
    public func canCreateCollection(existingNonSampleCount: Int) -> GateDecision {
        isPro || existingNonSampleCount < FreeTierLimits.collections ? .allowed : .requiresPro(.unlimitedCollections)
    }

    /// Adding a request to a collection that already has `requestCount` requests.
    public func canAddRequest(toCollectionWith requestCount: Int) -> GateDecision {
        isPro || requestCount < FreeTierLimits.requestsPerCollection ? .allowed : .requiresPro(.unlimitedCollections)
    }

    public var historyLimit: Int { FreeTierLimits.historyLimit(isPro: isPro) }

    /// Editing a collection beyond the free limits after Pro lapses is read-only (ADR-0012).
    public func isReadOnly(collectionIndexAmongNonSample index: Int, requestCount: Int) -> Bool {
        !isPro && (index >= FreeTierLimits.collections || requestCount > FreeTierLimits.requestsPerCollection)
    }
}

/// The app's current entitlement, observed by the UI. Phase 5 connects it to StoreKit (`EntitlementManager`).
@MainActor
@Observable
public final class EntitlementState {
    public private(set) var isPro: Bool

    public init(isPro: Bool = false) {
        self.isPro = isPro
    }

    public var gate: FeatureGate { FeatureGate(isPro: isPro) }

    public func update(isPro: Bool) {
        self.isPro = isPro
    }
}
