import Foundation

/// The App Store as the app uses it (B4). Live: ``LiveStoreClient`` (StoreKit 2); tests and UI tests:
/// ``FakeStoreClient``.
public protocol StoreClient: Sendable {
    /// Products in paywall order (yearly, monthly, lifetime); unknown or missing IDs are omitted.
    func products() async throws(StoreError) -> [StoreProduct]
    func purchase(_ id: ProductID) async throws(StoreError) -> PurchaseOutcome
    /// Verified, current entitlements (unverified transactions are never included).
    func currentEntitlements() async -> [TransactionSnapshot]
    /// Verified transactions that arrive outside a purchase call: Ask to Buy approvals, renewals, refunds,
    /// purchases on other devices (X03.2, X03.3).
    func transactionUpdates() async -> AsyncStream<TransactionSnapshot>
    /// "Restore Purchases": syncs with the App Store (may ask the user to sign in).
    func restore() async throws(StoreError)
}

/// Paywall display order.
extension ProductID {
    public static let paywallOrder: [ProductID] = [.yearly, .monthly, .lifetime]
}

/// Scripted store for unit and UI tests (no StoreKit).
public actor FakeStoreClient: StoreClient {
    public enum Script: Sendable {
        case succeed
        case cancel
        case pending
        case fail(StoreError)
    }

    public static let sampleProducts: [StoreProduct] = [
        StoreProduct(
            id: .yearly, displayName: "RequestPad Pro Yearly", description: "All Pro features, billed yearly.",
            displayPrice: "$19.99", price: 19.99, subscriptionPeriod: StorePeriod(value: 1, unit: .year),
            introductoryOffer: IntroductoryOffer(
                paymentMode: .freeTrial, period: StorePeriod(value: 1, unit: .week), displayPrice: "$0.00"),
            isEligibleForIntroductoryOffer: true),
        StoreProduct(
            id: .monthly, displayName: "RequestPad Pro Monthly", description: "All Pro features, billed monthly.",
            displayPrice: "$2.99", price: 2.99, subscriptionPeriod: StorePeriod(value: 1, unit: .month),
            introductoryOffer: IntroductoryOffer(
                paymentMode: .freeTrial, period: StorePeriod(value: 1, unit: .week), displayPrice: "$0.00"),
            isEligibleForIntroductoryOffer: true),
        StoreProduct(
            id: .lifetime, displayName: "RequestPad Pro Lifetime", description: "Unlock every Pro feature forever.",
            displayPrice: "$39.99", price: 39.99, subscriptionPeriod: nil),
    ]

    private var catalog: [StoreProduct]
    private var productsError: StoreError?
    private var entitlements: [TransactionSnapshot]
    private var nextScript: Script = .succeed
    private var restoreError: StoreError?
    private var continuations: [UUID: AsyncStream<TransactionSnapshot>.Continuation] = [:]
    private var nextID: UInt64 = 1
    private let now: @Sendable () -> Date

    public init(
        products: [StoreProduct] = FakeStoreClient.sampleProducts, entitlements: [TransactionSnapshot] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        catalog = products
        self.entitlements = entitlements
        self.now = now
    }

    // MARK: Scripting

    public func setNextPurchase(_ script: Script) { nextScript = script }
    public func setProductsError(_ error: StoreError?) { productsError = error }
    public func setRestoreError(_ error: StoreError?) { restoreError = error }

    /// Simulates a transaction arriving from outside (Ask to Buy approval, other device, renewal).
    public func deliver(_ transaction: TransactionSnapshot) {
        entitlements.removeAll { $0.id == transaction.id }
        entitlements.append(transaction)
        for continuation in continuations.values { continuation.yield(transaction) }
    }

    /// Simulates a refund: the transaction is revoked and delivered as an update.
    public func refund(_ productID: ProductID) {
        guard var transaction = entitlements.last(where: { $0.productID == productID.rawValue }) else { return }
        transaction.revocationDate = now()
        deliver(transaction)
    }

    public func makeTransaction(for id: ProductID) -> TransactionSnapshot {
        defer { nextID += 1 }
        let expiration: Date? =
            switch id {
            case .monthly: now().addingTimeInterval(30 * 86_400)
            case .yearly: now().addingTimeInterval(365 * 86_400)
            case .lifetime: nil
            }
        return TransactionSnapshot(id: nextID, productID: id.rawValue, purchaseDate: now(), expirationDate: expiration)
    }

    // MARK: StoreClient

    public func products() throws(StoreError) -> [StoreProduct] {
        if let productsError { throw productsError }
        return ProductID.paywallOrder.compactMap { id in catalog.first { $0.id == id } }
    }

    public func purchase(_ id: ProductID) throws(StoreError) -> PurchaseOutcome {
        guard catalog.contains(where: { $0.id == id }) else { throw .productNotFound(id) }
        switch nextScript {
        case .succeed:
            let transaction = makeTransaction(for: id)
            entitlements.append(transaction)
            return .purchased(transaction)
        case .cancel: return .cancelled
        case .pending: return .pending
        case .fail(let error): throw error
        }
    }

    public func currentEntitlements() -> [TransactionSnapshot] { entitlements }

    public func transactionUpdates() -> AsyncStream<TransactionSnapshot> {
        let (stream, continuation) = AsyncStream<TransactionSnapshot>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.unregister(id) } }
        return stream
    }

    public func restore() throws(StoreError) {
        if let restoreError { throw restoreError }
    }

    private func unregister(_ id: UUID) {
        continuations[id] = nil
    }
}
