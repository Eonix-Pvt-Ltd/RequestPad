import Foundation
import Observation

/// Purchases, restore and live entitlement updates (B4, X03). Owns ``EntitlementState``; the App Store's
/// current entitlements are the only source of truth (nothing is cached in UserDefaults, which users can edit).
@MainActor
@Observable
public final class EntitlementManager {
    public enum ProductsState: Equatable {
        case idle
        case loading
        case loaded
        case failed(StoreError)
    }

    public enum PurchaseState: Equatable {
        case idle
        case purchasing(ProductID)
        /// Ask to Buy or a payment that needs attention; Pro unlocks when the App Store approves it.
        case pending
        case failed(StoreError)
    }

    public enum RestoreResult: Equatable {
        case restored
        case nothingToRestore
        case failed(StoreError)
    }

    public let state: EntitlementState
    public private(set) var products: [StoreProduct] = []
    public private(set) var productsState: ProductsState = .idle
    public private(set) var purchaseState: PurchaseState = .idle
    public private(set) var source: EntitlementSource = .none
    public private(set) var isRestoring = false
    /// Set when Pro was just unlocked (purchase, approval, other device) so the UI can confirm it.
    public var didUnlockPro = false

    private let client: any StoreClient
    private let now: @Sendable () -> Date
    private var updatesTask: Task<Void, Never>?

    public init(client: any StoreClient, state: EntitlementState, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.state = state
        self.now = now
    }

    /// Reads current entitlements and listens for transactions from outside the app (X03.2, X03.3). Idempotent.
    public func start() async {
        await refreshEntitlements()
        guard updatesTask == nil else { return }
        let stream = await client.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.refreshEntitlements()
                if case .pending = self.purchaseState, self.source.isPro { self.purchaseState = .idle }
            }
        }
    }

    public func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    public func loadProducts() async {
        guard productsState != .loading else { return }
        productsState = .loading
        do {
            products = try await client.products()
            productsState = .loaded
        } catch {
            productsState = .failed(error)
        }
    }

    /// Returns true when Pro is active after the purchase.
    @discardableResult
    public func purchase(_ id: ProductID) async -> Bool {
        if case .purchasing = purchaseState { return false }
        purchaseState = .purchasing(id)
        do {
            switch try await client.purchase(id) {
            case .purchased:
                await refreshEntitlements()
                purchaseState = .idle
                return source.isPro
            case .pending:
                purchaseState = .pending
            case .cancelled:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error)
        }
        return false
    }

    public func restore() async -> RestoreResult {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await client.restore()
        } catch {
            return .failed(error)
        }
        await refreshEntitlements()
        return source.isPro ? .restored : .nothingToRestore
    }

    public func dismissPurchaseMessage() {
        if case .failed = purchaseState { purchaseState = .idle }
    }

    public func refreshEntitlements() async {
        let wasPro = source.isPro
        source = EntitlementResolver.resolve(await client.currentEntitlements(), now: now())
        state.update(isPro: source.isPro)
        if !wasPro && source.isPro { didUnlockPro = true }
    }
}
