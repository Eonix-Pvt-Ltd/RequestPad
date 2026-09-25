import Foundation
import RPStore
import StoreKit
import StoreKitTest
import Testing

@testable import RequestPad

/// Locates the test bundle, which carries `Products.storekit` (it is never shipped in the app).
private final class TestBundleToken {}

/// End-to-end StoreKit 2 flows against the local StoreKit configuration (X03.1–X03.3): the live client and the
/// entitlement manager, with purchases approved, deferred, refunded, expired and failed by `SKTestSession`.
@MainActor
@Suite("StoreKit", .serialized)
struct StoreKitTests {
    let session: SKTestSession
    let manager: EntitlementManager

    init() throws {
        let url = try #require(
            Bundle(for: TestBundleToken.self).url(forResource: "Products", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        manager = EntitlementManager(client: LiveStoreClient(), state: EntitlementState())
    }

    /// Requests right after a test session starts can fail on the simulator while the local StoreKit service comes
    /// up (the paywall's "Try Again" covers the same case for users). Each test starts once products load.
    private func waitForStore() async throws {
        for _ in 0..<40 {
            await manager.loadProducts()
            if manager.productsState == .loaded { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("The local StoreKit environment did not respond")
    }

    private func settle(_ timeout: Duration = .seconds(10), until condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func productsMatchTheConfiguration() async throws {
        try await waitForStore()
        #expect(manager.productsState == .loaded)
        #expect(manager.products.map(\.id) == [.yearly, .monthly, .lifetime])
        let yearly = try #require(manager.products.first)
        #expect(yearly.subscriptionPeriod == StorePeriod(value: 1, unit: .year))
        #expect(yearly.introductoryOffer?.paymentMode == .freeTrial)
        #expect(yearly.introductoryOffer?.period == StorePeriod(value: 1, unit: .week))
        #expect(yearly.isEligibleForIntroductoryOffer)
        #expect(PaywallCopy.offerLine(for: yearly)?.hasPrefix("7-day free trial, then") == true)
        #expect(try #require(manager.products.last).subscriptionPeriod == nil)
    }

    @Test func subscriptionPurchaseUnlocksPro() async throws {
        try await waitForStore()
        await manager.start()
        defer { manager.stop() }
        #expect(!manager.state.isPro)
        #expect(await manager.purchase(.yearly))
        #expect(manager.state.isPro)
        guard case .subscription(.yearly, let renews) = manager.source else {
            Issue.record("Expected a yearly subscription, got \(manager.source)")
            return
        }
        #expect(renews != nil)
    }

    @Test func lifetimePurchaseUnlocksPro() async throws {
        try await waitForStore()
        #expect(await manager.purchase(.lifetime))
        #expect(manager.source == .lifetime)
    }

    @Test func askToBuyStaysPendingUntilApproved() async throws {
        try await waitForStore()
        session.askToBuyEnabled = true
        await manager.start()
        defer { manager.stop() }
        #expect(!(await manager.purchase(.monthly)))
        #expect(manager.purchaseState == .pending)
        #expect(!manager.state.isPro)
        let pending = try #require(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        await settle { manager.state.isPro }
        #expect(manager.state.isPro)
        #expect(manager.purchaseState == .idle)
    }

    @Test func refundRevokesPro() async throws {
        try await waitForStore()
        await manager.start()
        defer { manager.stop() }
        #expect(await manager.purchase(.lifetime))
        let transaction = try #require(
            session.allTransactions().first { $0.productIdentifier == ProductID.lifetime.rawValue })
        try session.refundTransaction(identifier: transaction.identifier)
        await settle { !manager.state.isPro }
        #expect(!manager.state.isPro)
    }

    @Test func subscriptionEndsWhenItsPeriodIsOver() async throws {
        try await waitForStore()
        // Accelerated time: a subscription period (and the trial) lasts seconds.
        session.timeRate = .oneRenewalEveryTwoSeconds
        defer { session.timeRate = .realTime }
        #expect(await manager.purchase(.monthly))
        #expect(manager.state.isPro)
        // Turn off renewal; Pro must end with the current period (no transaction update is sent for that).
        try session.expireSubscription(productIdentifier: ProductID.monthly.rawValue)
        for _ in 0..<100 where manager.state.isPro {
            try await Task.sleep(for: .milliseconds(200))
            await manager.refreshEntitlements()
        }
        #expect(!manager.state.isPro)
    }

    @Test func failedPurchaseLeavesFreeWithAMessage() async throws {
        try await waitForStore()
        try await session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        #expect(!(await manager.purchase(.yearly)))
        #expect(!manager.state.isPro)
        guard case .failed(let error) = manager.purchaseState else {
            Issue.record("Expected a failure, got \(manager.purchaseState)")
            return
        }
        #expect(error == .network || error == .purchaseFailed)
        try await session.setSimulatedError(nil, forAPI: .purchase)
    }

    @Test func purchaseMadeElsewhereArrivesAsAnUpdate() async throws {
        try await waitForStore()
        await manager.start()
        defer { manager.stop() }
        try await session.buyProduct(identifier: ProductID.yearly.rawValue)
        await settle { manager.state.isPro }
        #expect(manager.state.isPro)
    }

    @Test func restoreFindsExistingPurchases() async throws {
        try await waitForStore()
        #expect(await manager.restore() == .nothingToRestore)
        try await session.buyProduct(identifier: ProductID.lifetime.rawValue)
        #expect(await manager.restore() == .restored)
    }
}
