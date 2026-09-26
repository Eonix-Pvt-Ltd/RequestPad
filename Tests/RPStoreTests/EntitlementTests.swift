import Foundation
import Testing

@testable import RPStore

@Suite("EntitlementResolver")
struct EntitlementResolverTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func transaction(
        _ id: ProductID, expires offset: TimeInterval? = nil, revoked: Bool = false, upgraded: Bool = false,
        number: UInt64 = 1
    ) -> TransactionSnapshot {
        TransactionSnapshot(
            id: number, productID: id.rawValue, purchaseDate: now.addingTimeInterval(-86_400),
            expirationDate: offset.map { now.addingTimeInterval($0) }, revocationDate: revoked ? now : nil,
            isUpgraded: upgraded)
    }

    @Test func noTransactionsIsFree() {
        #expect(EntitlementResolver.resolve([], now: now) == .none)
        #expect(!EntitlementSource.none.isPro)
    }

    @Test func lifetimeWinsOverSubscriptions() {
        let result = EntitlementResolver.resolve(
            [transaction(.monthly, expires: 3600), transaction(.lifetime, number: 2)], now: now)
        #expect(result == .lifetime)
    }

    @Test func activeSubscriptionReportsItsEnd() {
        let result = EntitlementResolver.resolve([transaction(.yearly, expires: 3600)], now: now)
        #expect(result == .subscription(.yearly, renewsOrExpires: now.addingTimeInterval(3600)))
        #expect(result.isPro)
    }

    @Test func expiredRevokedAndUpgradedDoNotCount() {
        #expect(EntitlementResolver.resolve([transaction(.monthly, expires: -1)], now: now) == .none)
        #expect(EntitlementResolver.resolve([transaction(.lifetime, revoked: true)], now: now) == .none)
        #expect(EntitlementResolver.resolve([transaction(.monthly, expires: 3600, upgraded: true)], now: now) == .none)
    }

    @Test func unknownProductsAreIgnored() {
        let foreign = TransactionSnapshot(id: 9, productID: "com.example.other", purchaseDate: now)
        #expect(EntitlementResolver.resolve([foreign], now: now) == .none)
    }

    @Test func latestEndingSubscriptionIsReported() {
        let result = EntitlementResolver.resolve(
            [transaction(.monthly, expires: 100), transaction(.yearly, expires: 9_000, number: 2)], now: now)
        #expect(result == .subscription(.yearly, renewsOrExpires: now.addingTimeInterval(9_000)))
    }
}

@Suite("PaywallCopy")
struct PaywallCopyTests {
    let products = FakeStoreClient.sampleProducts

    @Test func priceLines() {
        #expect(PaywallCopy.priceLine(for: products[0]) == "$19.99/year")
        #expect(PaywallCopy.priceLine(for: products[1]) == "$2.99/month")
        #expect(PaywallCopy.priceLine(for: products[2]) == "$39.99 once")
    }

    @Test func trialLineOnlyWhenEligible() {
        #expect(PaywallCopy.offerLine(for: products[0]) == "7-day free trial, then $19.99/year.")
        var ineligible = products[0]
        ineligible.isEligibleForIntroductoryOffer = false
        #expect(PaywallCopy.offerLine(for: ineligible) == nil)
        #expect(PaywallCopy.offerLine(for: products[2]) == nil)
    }

    @Test func paidIntroductoryOffer() {
        var product = products[1]
        product.introductoryOffer = IntroductoryOffer(
            paymentMode: .payUpFront, period: StorePeriod(value: 3, unit: .month), displayPrice: "$4.99")
        #expect(PaywallCopy.offerLine(for: product) == "$4.99 for the first 3 months, then $2.99/month.")
    }

    @Test func periodDescriptions() {
        #expect(StorePeriod(value: 2, unit: .week).adjectiveDescription == "14-day")
        #expect(StorePeriod(value: 3, unit: .day).unitDescription == "3 days")
        #expect(StorePeriod(value: 1, unit: .week).unitDescription == "week")
        #expect(StorePeriod(value: 2, unit: .year).unitDescription == "2 years")
        #expect(StorePeriod(value: 1, unit: .year).adjectiveDescription == "1-year")
    }

    @Test func termsMentionRenewalAndCancellation() {
        #expect(PaywallCopy.subscriptionTerms.contains("24 hours"))
        #expect(PaywallCopy.subscriptionTerms.contains("renew"))
    }

    @Test func statusLines() {
        #expect(PaywallCopy.statusLine(for: .none) == "Free")
        #expect(PaywallCopy.statusLine(for: .lifetime) == "Pro — Lifetime")
        #expect(PaywallCopy.statusLine(for: .subscription(.monthly, renewsOrExpires: nil)) == "Pro — Monthly")
        #expect(
            PaywallCopy.statusLine(for: .subscription(.yearly, renewsOrExpires: Date())).hasPrefix(
                "Pro — Yearly, renews"))
    }

    @Test(arguments: [
        StoreError.productsUnavailable, .productNotFound(.monthly), .verificationFailed, .purchaseFailed,
        .purchasesNotAllowed, .restoreFailed, .network,
    ])
    func errorsArePresentable(error: StoreError) {
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.recoverySuggestion?.isEmpty == false)
    }
}

@MainActor
@Suite("EntitlementManager")
struct EntitlementManagerTests {
    private func makeManager(_ client: FakeStoreClient = FakeStoreClient()) -> (EntitlementManager, FakeStoreClient) {
        (EntitlementManager(client: client, state: EntitlementState()), client)
    }

    /// Waits for the updates listener to process a delivered transaction.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func loadsProductsInPaywallOrder() async {
        let (manager, _) = makeManager()
        await manager.loadProducts()
        #expect(manager.productsState == .loaded)
        #expect(manager.products.map(\.id) == [.yearly, .monthly, .lifetime])
    }

    @Test func productLoadFailureIsRetryable() async {
        let (manager, client) = makeManager()
        await client.setProductsError(.network)
        await manager.loadProducts()
        #expect(manager.productsState == .failed(.network))
        await client.setProductsError(nil)
        await manager.loadProducts()
        #expect(manager.productsState == .loaded)
    }

    @Test func purchaseUnlocksProImmediately() async {
        let (manager, _) = makeManager()
        await manager.start()
        #expect(!manager.state.isPro)
        #expect(await manager.purchase(.yearly))
        #expect(manager.state.isPro)
        #expect(manager.didUnlockPro)
        #expect(manager.purchaseState == .idle)
        if case .subscription(.yearly, _) = manager.source {
        } else {
            Issue.record("Expected yearly, got \(manager.source)")
        }
    }

    @Test func cancelledPurchaseChangesNothing() async {
        let (manager, client) = makeManager()
        await client.setNextPurchase(.cancel)
        #expect(!(await manager.purchase(.monthly)))
        #expect(!manager.state.isPro)
        #expect(manager.purchaseState == .idle)
    }

    @Test func failedPurchaseShowsAMessage() async {
        let (manager, client) = makeManager()
        await client.setNextPurchase(.fail(.purchasesNotAllowed))
        #expect(!(await manager.purchase(.lifetime)))
        #expect(manager.purchaseState == .failed(.purchasesNotAllowed))
        manager.dismissPurchaseMessage()
        #expect(manager.purchaseState == .idle)
    }

    @Test func askToBuyIsPendingUntilApproved() async {
        let (manager, client) = makeManager()
        await manager.start()
        await client.setNextPurchase(.pending)
        #expect(!(await manager.purchase(.monthly)))
        #expect(manager.purchaseState == .pending)
        #expect(!manager.state.isPro)
        await client.deliver(await client.makeTransaction(for: .monthly))
        await settle { manager.state.isPro }
        #expect(manager.state.isPro)
        #expect(manager.purchaseState == .idle)
    }

    @Test func refundRevokesPro() async {
        let (manager, client) = makeManager()
        await manager.start()
        await manager.purchase(.lifetime)
        #expect(manager.state.isPro)
        await client.refund(.lifetime)
        await settle { !manager.state.isPro }
        #expect(!manager.state.isPro)
        #expect(manager.source == .none)
    }

    @Test func purchaseOnAnotherDeviceArrivesAsAnUpdate() async {
        let (manager, client) = makeManager()
        await manager.start()
        await client.deliver(await client.makeTransaction(for: .yearly))
        await settle { manager.state.isPro }
        #expect(manager.state.isPro)
    }

    @Test func restoreReportsWhatHappened() async {
        let (manager, client) = makeManager()
        #expect(await manager.restore() == .nothingToRestore)
        await client.deliver(await client.makeTransaction(for: .lifetime))
        #expect(await manager.restore() == .restored)
        await client.setRestoreError(.restoreFailed)
        #expect(await manager.restore() == .failed(.restoreFailed))
    }

    @Test func existingEntitlementIsReadAtStart() async {
        let client = FakeStoreClient()
        await client.deliver(await client.makeTransaction(for: .lifetime))
        let (manager, _) = makeManager(client)
        await manager.start()
        #expect(manager.state.isPro)
        #expect(manager.source == .lifetime)
        // An existing purchase is restored silently at launch, not announced as a new unlock.
        #expect(!manager.didUnlockPro)
        manager.stop()
    }

    @Test func overlappingStartsAtLaunchAreNotAnUnlock() async {
        let client = FakeStoreClient()
        await client.deliver(await client.makeTransaction(for: .lifetime))
        let (manager, _) = makeManager(client)
        // Windows, the menu bar and Shortcuts can start the store at the same moment.
        async let first: Void = manager.start()
        async let second: Void = manager.refreshEntitlements()
        _ = await (first, second)
        #expect(manager.state.isPro)
        #expect(!manager.didUnlockPro)
        manager.stop()
    }

    @Test func expiredSubscriptionIsFreeAfterRefresh() async {
        let clock = Clock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let client = FakeStoreClient(now: { clock.date })
        let manager = EntitlementManager(client: client, state: EntitlementState(), now: { clock.date })
        await manager.purchase(.monthly)
        #expect(manager.state.isPro)
        clock.date = clock.date.addingTimeInterval(31 * 86_400)
        await manager.refreshEntitlements()
        #expect(!manager.state.isPro)
    }

    @Test func unknownProductCannotBeBought() async {
        let client = FakeStoreClient(products: [FakeStoreClient.sampleProducts[2]])
        let (manager, _) = makeManager(client)
        #expect(!(await manager.purchase(.yearly)))
        #expect(manager.purchaseState == .failed(.productNotFound(.yearly)))
    }
}

/// A settable clock for expiry tests.
final class Clock: @unchecked Sendable {
    // @unchecked: `storage` is only accessed under `lock`.
    private let lock = NSLock()
    private var storage: Date

    init(date: Date) {
        storage = date
    }

    var date: Date {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
