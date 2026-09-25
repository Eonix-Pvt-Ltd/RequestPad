import Foundation
import OSLog
import RPCore
import RPStore
import StoreKit

/// StoreKit 2 implementation (B4), in the app target so RPStore stays pure (tested by `StoreKitTests`). Only transactions whose JWS verifies are used; unverified ones are logged
/// (without identifiers) and never grant Pro. Transactions are finished after they have been delivered.
actor LiveStoreClient: StoreClient {
    private var cache: [ProductID: Product] = [:]
    private let log = Logger(subsystem: AppConstants.loggingSubsystem, category: "store")

    init() {}

    func products() async throws(StoreError) -> [StoreProduct] {
        do {
            let loaded = try await Product.products(for: ProductID.paywallOrder.map(\.rawValue))
            var result: [StoreProduct] = []
            for product in loaded {
                guard let id = ProductID(rawValue: product.id) else { continue }
                cache[id] = product
                result.append(await Self.makeStoreProduct(product, id: id))
            }
            guard !result.isEmpty else { throw StoreError.productsUnavailable }
            return ProductID.paywallOrder.compactMap { id in result.first { $0.id == id } }
        } catch let error as StoreError {
            throw error
        } catch {
            log.error("Loading products failed: \(String(describing: type(of: error)), privacy: .public)")
            throw Self.map(error, fallback: .productsUnavailable)
        }
    }

    func purchase(_ id: ProductID) async throws(StoreError) -> PurchaseOutcome {
        let product: Product
        if let cached = cache[id] {
            product = cached
        } else {
            _ = try await products()
            guard let loaded = cache[id] else { throw .productNotFound(id) }
            product = loaded
        }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            log.error("Purchase failed: \(String(describing: type(of: error)), privacy: .public)")
            throw Self.map(error, fallback: .purchaseFailed)
        }
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                log.error("Purchase returned an unverified transaction")
                throw .verificationFailed
            }
            let snapshot = Self.snapshot(transaction)
            await transaction.finish()
            return .purchased(snapshot)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func currentEntitlements() async -> [TransactionSnapshot] {
        var snapshots: [TransactionSnapshot] = []
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else {
                log.error("Ignoring an unverified entitlement")
                continue
            }
            snapshots.append(Self.snapshot(transaction))
        }
        return snapshots
    }

    func transactionUpdates() -> AsyncStream<TransactionSnapshot> {
        let log = log
        return AsyncStream { continuation in
            let task = Task {
                for await verification in Transaction.updates {
                    guard case .verified(let transaction) = verification else {
                        log.error("Ignoring an unverified transaction update")
                        continue
                    }
                    continuation.yield(Self.snapshot(transaction))
                    await transaction.finish()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func restore() async throws(StoreError) {
        do {
            try await AppStore.sync()
        } catch {
            log.error("Restore failed: \(String(describing: type(of: error)), privacy: .public)")
            throw Self.map(error, fallback: .restoreFailed)
        }
    }

    // MARK: Mapping

    nonisolated static func snapshot(_ transaction: Transaction) -> TransactionSnapshot {
        TransactionSnapshot(
            id: transaction.id, productID: transaction.productID, purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate, revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded)
    }

    nonisolated static func makeStoreProduct(_ product: Product, id: ProductID) async -> StoreProduct {
        let subscription = product.subscription
        let offer = subscription?.introductoryOffer.map { offer in
            IntroductoryOffer(
                paymentMode: paymentMode(offer.paymentMode), period: period(offer.period),
                displayPrice: offer.displayPrice, periodCount: offer.periodCount)
        }
        let eligible = await subscription?.isEligibleForIntroOffer ?? false
        return StoreProduct(
            id: id, displayName: product.displayName, description: product.description,
            displayPrice: product.displayPrice, price: product.price,
            subscriptionPeriod: subscription.map { period($0.subscriptionPeriod) }, introductoryOffer: offer,
            isEligibleForIntroductoryOffer: eligible)
    }

    nonisolated static func period(_ period: Product.SubscriptionPeriod) -> StorePeriod {
        let unit: StorePeriod.Unit =
            switch period.unit {
            case .day: .day
            case .week: .week
            case .month: .month
            case .year: .year
            @unknown default: .month
            }
        return StorePeriod(value: period.value, unit: unit)
    }

    nonisolated static func paymentMode(_ mode: Product.SubscriptionOffer.PaymentMode) -> IntroductoryOffer.PaymentMode
    {
        switch mode {
        case .freeTrial: .freeTrial
        case .payUpFront: .payUpFront
        default: .payAsYouGo
        }
    }

    nonisolated static func map(_ error: any Error, fallback: StoreError) -> StoreError {
        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .purchaseNotAllowed: return .purchasesNotAllowed
            case .productUnavailable: return .productsUnavailable
            default: return fallback
            }
        }
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .networkError: return .network
            case .notAvailableInStorefront: return .productsUnavailable
            default: return fallback
            }
        }
        return fallback
    }
}
