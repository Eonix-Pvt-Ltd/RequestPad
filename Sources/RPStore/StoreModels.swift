import Foundation

/// A subscription or introductory-offer period ("1 week", "1 year").
public struct StorePeriod: Sendable, Hashable {
    public enum Unit: String, Sendable, Hashable {
        case day, week, month, year
    }

    public var value: Int
    public var unit: Unit

    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// "7-day", "1-month" — used in "7-day free trial".
    public var adjectiveDescription: String {
        let days = unit == .week ? value * 7 : value
        switch unit {
        case .day, .week: return String(localized: "\(days)-day", bundle: .module)
        case .month: return String(localized: "\(value)-month", bundle: .module)
        case .year: return String(localized: "\(value)-year", bundle: .module)
        }
    }

    /// "year", "month", "3 months" — used in "$19.99/year".
    public var unitDescription: String {
        switch (unit, value) {
        case (.day, 1): String(localized: "day", bundle: .module)
        case (.week, 1): String(localized: "week", bundle: .module)
        case (.month, 1): String(localized: "month", bundle: .module)
        case (.year, 1): String(localized: "year", bundle: .module)
        case (.day, _): String(localized: "\(value) days", bundle: .module)
        case (.week, _): String(localized: "\(value) weeks", bundle: .module)
        case (.month, _): String(localized: "\(value) months", bundle: .module)
        case (.year, _): String(localized: "\(value) years", bundle: .module)
        }
    }
}

/// An introductory offer on a subscription (the 7-day free trial, B4).
public struct IntroductoryOffer: Sendable, Hashable {
    public enum PaymentMode: Sendable, Hashable {
        case freeTrial
        case payAsYouGo
        case payUpFront
    }

    public var paymentMode: PaymentMode
    public var period: StorePeriod
    public var displayPrice: String
    public var periodCount: Int

    public init(paymentMode: PaymentMode, period: StorePeriod, displayPrice: String, periodCount: Int = 1) {
        self.paymentMode = paymentMode
        self.period = period
        self.displayPrice = displayPrice
        self.periodCount = periodCount
    }
}

/// A product as the paywall shows it; prices come from the App Store, never from the app (B4).
public struct StoreProduct: Sendable, Hashable, Identifiable {
    public var id: ProductID
    public var displayName: String
    public var description: String
    public var displayPrice: String
    public var price: Decimal
    /// `nil` for the lifetime (non-consumable) product.
    public var subscriptionPeriod: StorePeriod?
    public var introductoryOffer: IntroductoryOffer?
    /// Apple decides eligibility (one trial per subscription group per Apple Account).
    public var isEligibleForIntroductoryOffer: Bool

    public init(
        id: ProductID, displayName: String, description: String, displayPrice: String, price: Decimal,
        subscriptionPeriod: StorePeriod?, introductoryOffer: IntroductoryOffer? = nil,
        isEligibleForIntroductoryOffer: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.price = price
        self.subscriptionPeriod = subscriptionPeriod
        self.introductoryOffer = introductoryOffer
        self.isEligibleForIntroductoryOffer = isEligibleForIntroductoryOffer
    }

    /// The offer the buyer actually gets now (only when eligible).
    public var activeIntroductoryOffer: IntroductoryOffer? {
        isEligibleForIntroductoryOffer ? introductoryOffer : nil
    }
}

/// A verified App Store transaction, reduced to what entitlement decisions need.
public struct TransactionSnapshot: Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var productID: String
    public var purchaseDate: Date
    public var expirationDate: Date?
    public var revocationDate: Date?
    /// A newer transaction in the same subscription group replaced this one.
    public var isUpgraded: Bool

    public init(
        id: UInt64, productID: String, purchaseDate: Date, expirationDate: Date? = nil, revocationDate: Date? = nil,
        isUpgraded: Bool = false
    ) {
        self.id = id
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
    }
}

/// What a completed purchase flow produced.
public enum PurchaseOutcome: Sendable, Hashable {
    case purchased(TransactionSnapshot)
    /// Waiting for approval (Ask to Buy) or for the payment method (X03.2).
    case pending
    case cancelled
}

/// Store failures with user-facing text that reveals no internals (B4, B1).
public enum StoreError: Error, Hashable, Sendable, LocalizedError {
    case productsUnavailable
    case productNotFound(ProductID)
    case verificationFailed
    case purchaseFailed
    case purchasesNotAllowed
    case restoreFailed
    case network

    public var errorDescription: String? {
        switch self {
        case .productsUnavailable: String(localized: "Prices Aren't Available Right Now", bundle: .module)
        case .productNotFound: String(localized: "This Option Isn't Available", bundle: .module)
        case .verificationFailed: String(localized: "The Purchase Couldn't Be Verified", bundle: .module)
        case .purchaseFailed: String(localized: "The Purchase Didn't Go Through", bundle: .module)
        case .purchasesNotAllowed: String(localized: "Purchases Are Turned Off", bundle: .module)
        case .restoreFailed: String(localized: "Purchases Couldn't Be Restored", bundle: .module)
        case .network: String(localized: "No Connection to the App Store", bundle: .module)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .productsUnavailable, .network:
            String(localized: "Check your internet connection and try again.", bundle: .module)
        case .productNotFound:
            String(localized: "Try again later or choose another option.", bundle: .module)
        case .verificationFailed:
            String(
                localized: "You weren't charged for an unverified purchase. Try again or contact support.",
                bundle: .module)
        case .purchaseFailed:
            String(localized: "You weren't charged. Try again in a moment.", bundle: .module)
        case .purchasesNotAllowed:
            String(localized: "In-app purchases are restricted on this device (Screen Time).", bundle: .module)
        case .restoreFailed:
            String(
                localized:
                    "Make sure you're signed in to the App Store with the Apple Account you purchased with, then try again.",
                bundle: .module)
        }
    }
}
