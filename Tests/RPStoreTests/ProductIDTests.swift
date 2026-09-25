import Testing

@testable import RPStore

@Suite("ProductID")
struct ProductIDTests {
    @Test func identifiersMatchAppStoreConnect() {
        #expect(ProductID.monthly.rawValue == "lk.eonix.requestpad.pro.monthly")
        #expect(ProductID.yearly.rawValue == "lk.eonix.requestpad.pro.yearly")
        #expect(ProductID.lifetime.rawValue == "lk.eonix.requestpad.pro.lifetime")
        #expect(ProductID.subscriptionGroupName == "Pro")
    }

    @Test func subscriptionKinds() {
        #expect(ProductID.subscriptions == [.monthly, .yearly])
        #expect(!ProductID.lifetime.isSubscription)
    }

    @Test func freeTierLimits() {
        #expect(FreeTierLimits.collections == 1)
        #expect(FreeTierLimits.requestsPerCollection == 30)
        #expect(FreeTierLimits.historyLimit(isPro: false) == 100)
        #expect(FreeTierLimits.historyLimit(isPro: true) == 1_000)
    }
}
