import Foundation

/// Why the user has Pro (or not).
public enum EntitlementSource: Sendable, Hashable {
    case none
    case lifetime
    /// `renewsOrExpires` is the current period's end.
    case subscription(ProductID, renewsOrExpires: Date?)

    public var isPro: Bool { self != .none }
}

/// Decides the entitlement from verified transactions (X03.2). Pure, so every purchase, expiry, upgrade and
/// refund case is unit-tested.
public enum EntitlementResolver {
    public static func resolve(_ transactions: [TransactionSnapshot], now: Date) -> EntitlementSource {
        let active = transactions.filter { transaction in
            guard transaction.revocationDate == nil, !transaction.isUpgraded,
                ProductID(rawValue: transaction.productID) != nil
            else { return false }
            if let expiration = transaction.expirationDate { return expiration > now }
            return true
        }
        if active.contains(where: { $0.productID == ProductID.lifetime.rawValue }) { return .lifetime }
        let subscription = active.compactMap { transaction -> (ProductID, Date?)? in
            guard let id = ProductID(rawValue: transaction.productID), id.isSubscription else { return nil }
            return (id, transaction.expirationDate)
        }
        .max { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
        if let subscription { return .subscription(subscription.0, renewsOrExpires: subscription.1) }
        return .none
    }
}

/// Paywall text built from App Store product data (X03.1, App Review 3.1.2).
public enum PaywallCopy {
    /// "$19.99/year" or "$39.99 once".
    public static func priceLine(for product: StoreProduct) -> String {
        guard let period = product.subscriptionPeriod else {
            return String(localized: "\(product.displayPrice) once", bundle: .module)
        }
        return String(localized: "\(product.displayPrice)/\(period.unitDescription)", bundle: .module)
    }

    /// "7-day free trial, then $19.99/year." — only when the buyer is eligible for the offer.
    public static func offerLine(for product: StoreProduct) -> String? {
        guard let offer = product.activeIntroductoryOffer else { return nil }
        let after = priceLine(for: product)
        switch offer.paymentMode {
        case .freeTrial:
            return String(localized: "\(offer.period.adjectiveDescription) free trial, then \(after).", bundle: .module)
        case .payAsYouGo, .payUpFront:
            return String(
                localized: "\(offer.displayPrice) for the first \(offer.period.unitDescription), then \(after).",
                bundle: .module)
        }
    }

    /// The auto-renewal disclosure App Review requires next to subscription purchase buttons.
    public static let subscriptionTerms = String(
        localized: """
            Subscriptions renew automatically at the price shown unless cancelled at least 24 hours before the end of \
            the current period. Payment is charged to your Apple Account at confirmation of purchase (or when a free \
            trial ends). Manage or cancel in your App Store account settings. Lifetime is a one-time purchase.
            """, bundle: .module)

    /// A short line for Settings describing the current entitlement.
    public static func statusLine(for source: EntitlementSource, now: Date = Date()) -> String {
        switch source {
        case .none:
            return String(localized: "Free", bundle: .module)
        case .lifetime:
            return String(localized: "Pro — Lifetime", bundle: .module)
        case .subscription(let id, let date):
            let plan =
                id == .yearly
                ? String(localized: "Yearly", bundle: .module) : String(localized: "Monthly", bundle: .module)
            guard let date else { return String(localized: "Pro — \(plan)", bundle: .module) }
            return String(
                localized: "Pro — \(plan), renews or ends \(date.formatted(date: .abbreviated, time: .omitted))",
                bundle: .module)
        }
    }
}
