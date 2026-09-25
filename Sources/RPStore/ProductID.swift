import Foundation

/// App Store product identifiers (B4, ADR-0002). These must match App Store Connect and `Products.storekit`.
public enum ProductID: String, CaseIterable, Sendable {
    case monthly = "lk.eonix.requestpad.pro.monthly"
    case yearly = "lk.eonix.requestpad.pro.yearly"
    case lifetime = "lk.eonix.requestpad.pro.lifetime"

    /// Reference name of the auto-renewable subscription group.
    public static let subscriptionGroupName = "Pro"

    public var isSubscription: Bool {
        switch self {
        case .monthly, .yearly: true
        case .lifetime: false
        }
    }

    public static var subscriptions: [ProductID] { allCases.filter(\.isSubscription) }
}

/// Limits of the free tier (PRD §4, ADR-0008, ADR-0009).
public enum FreeTierLimits {
    /// Collections a free user may create, excluding the Sample collection.
    public static let collections = 1
    /// Requests per collection on the free tier.
    public static let requestsPerCollection = 30
    public static let historyEntries = 100
    public static let proHistoryEntries = 1_000

    public static func historyLimit(isPro: Bool) -> Int {
        isPro ? proHistoryEntries : historyEntries
    }
}
