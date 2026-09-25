import Testing

@testable import RPStore

@Suite("FeatureGate")
struct FeatureGateTests {
    @Test(arguments: ProFeature.allCases)
    func freeTierRequiresProForEveryProFeature(feature: ProFeature) {
        #expect(FeatureGate(isPro: false).check(feature) == .requiresPro(feature))
        #expect(FeatureGate(isPro: true).check(feature) == .allowed)
        #expect(!feature.title.isEmpty && !feature.systemImage.isEmpty)
        #expect(feature.id == feature.rawValue)
    }

    @Test func collectionAndRequestLimits() {
        let free = FeatureGate(isPro: false)
        #expect(free.canCreateCollection(existingNonSampleCount: 0) == .allowed)
        #expect(free.canCreateCollection(existingNonSampleCount: 1) == .requiresPro(.unlimitedCollections))
        #expect(free.canAddRequest(toCollectionWith: 29) == .allowed)
        #expect(free.canAddRequest(toCollectionWith: 30) == .requiresPro(.unlimitedCollections))
        let pro = FeatureGate(isPro: true)
        #expect(pro.canCreateCollection(existingNonSampleCount: 50) == .allowed)
        #expect(pro.canAddRequest(toCollectionWith: 500) == .allowed)
        #expect(free.historyLimit == 100)
        #expect(pro.historyLimit == 1_000)
    }

    @Test func lapsedProDataBecomesReadOnlyBeyondLimits() {
        let free = FeatureGate(isPro: false)
        #expect(!free.isReadOnly(collectionIndexAmongNonSample: 0, requestCount: 30))
        #expect(free.isReadOnly(collectionIndexAmongNonSample: 0, requestCount: 31))
        #expect(free.isReadOnly(collectionIndexAmongNonSample: 1, requestCount: 1))
        #expect(!FeatureGate(isPro: true).isReadOnly(collectionIndexAmongNonSample: 5, requestCount: 500))
    }

    @MainActor
    @Test func entitlementState() {
        let state = EntitlementState()
        #expect(!state.isPro)
        #expect(state.gate == FeatureGate(isPro: false))
        state.update(isPro: true)
        #expect(state.gate.isPro)
    }
}
