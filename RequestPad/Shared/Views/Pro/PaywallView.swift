import RPCore
import RPStore
import RPUI
import StoreKit
import SwiftUI

/// The one paywall (B4, X03.1): App Store prices, trial terms, lifetime option, Restore Purchases, Terms and
/// Privacy links, and a close control. Shown for every Pro trigger.
struct PaywallView: View {
    let app: AppModel
    /// The feature that led here, if any.
    let feature: ProFeature?
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var selection: ProductID = .yearly
    @State private var restoreResult: EntitlementManager.RestoreResult?

    private var store: EntitlementManager { app.store }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    header
                    if store.source.isPro {
                        activeSection
                    } else {
                        // Plans and the purchase button first, so prices are visible without scrolling (iPad
                        // form sheets are short).
                        productsSection
                        FeatureList()
                    }
                    legalSection
                }
                .padding(Spacing.large)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("RequestPad Pro")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                        .accessibilityIdentifier("paywall.close")
                }
            }
        }
        .sheetFrame(minWidth: 460, minHeight: 600)
        .task { await store.loadProducts() }
        .onChange(of: store.source.isPro) { _, isPro in
            if isPro { dismiss() }
        }
        .alert(item: restoreAlertBinding) { result in
            Alert(title: Text(result.title), message: Text(result.message))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let feature {
                Label(feature.title, systemImage: feature.systemImage)
                    .font(.title3.bold())
                    .accessibilityIdentifier("paywall.feature")
                Text("This is part of RequestPad Pro.")
                    .foregroundStyle(Color.textSecondary)
            } else {
                Text("Unlock everything in RequestPad")
                    .font(.title3.bold())
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var productsSection: some View {
        switch store.productsState {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView("Loading prices…")
                Spacer()
            }
            .frame(minHeight: 160)
        case .failed(let error):
            VStack(alignment: .leading, spacing: Spacing.small) {
                Label(error.errorDescription ?? "", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                Text(error.recoverySuggestion ?? "")
                    .foregroundStyle(Color.textSecondary)
                Button("Try Again") { Task { await store.loadProducts() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("paywall.retry")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded:
            VStack(alignment: .leading, spacing: Spacing.small) {
                ForEach(store.products) { product in
                    ProductOption(product: product, isSelected: selection == product.id) { selection = product.id }
                }
            }
            purchaseArea
        }
    }

    @ViewBuilder private var purchaseArea: some View {
        let product = store.products.first { $0.id == selection }
        VStack(spacing: Spacing.small) {
            if let product, let offer = PaywallCopy.offerLine(for: product) {
                Text(offer)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.offer")
            }
            Button {
                Task { await store.purchase(selection) }
            } label: {
                Group {
                    if case .purchasing = store.purchaseState {
                        ProgressView()
                    } else {
                        Text(purchaseTitle(for: product))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .prominentButtonStyle()
            .controlSize(.large)
            .disabled(product == nil || store.purchaseState == .purchasing(selection))
            .accessibilityIdentifier("paywall.purchase")
            switch store.purchaseState {
            case .pending:
                NoticeBanner(
                    systemImage: "hourglass",
                    message: Text("Waiting for approval. Pro unlocks as soon as the purchase is approved."),
                    tint: .textBlue
                )
                .accessibilityIdentifier("paywall.pending")
            case .failed(let error):
                NoticeBanner(
                    systemImage: "exclamationmark.triangle.fill",
                    message: Text("\(error.errorDescription ?? "") \(error.recoverySuggestion ?? "")"),
                    tint: .textOrange
                ) {
                    Button("OK") { store.dismissPurchaseMessage() }
                        .buttonStyle(.borderless)
                }
                .accessibilityIdentifier("paywall.error")
            case .idle, .purchasing:
                EmptyView()
            }
            Button(store.isRestoring ? "Restoring…" : "Restore Purchases") {
                Task { restoreResult = await store.restore() }
            }
            .disabled(store.isRestoring)
            .accessibilityIdentifier("paywall.restore")
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("You have RequestPad Pro", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(Color.textGreen)
            Text(PaywallCopy.statusLine(for: store.source))
                .foregroundStyle(Color.textSecondary)
            ManageSubscriptionButton(source: store.source)
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(PaywallCopy.subscriptionTerms)
                .font(.footnote)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.medium) {
                Link("Terms of Use", destination: AppLinks.terms)
                Link("Privacy Policy", destination: AppLinks.privacy)
            }
            .font(.footnote)
        }
    }

    private func purchaseTitle(for product: StoreProduct?) -> String {
        guard let product else { return String(localized: "Continue") }
        if product.activeIntroductoryOffer?.paymentMode == .freeTrial { return String(localized: "Start Free Trial") }
        return product.subscriptionPeriod == nil ? String(localized: "Buy Lifetime") : String(localized: "Subscribe")
    }

    private var restoreAlertBinding: Binding<RestoreAlert?> {
        Binding(
            get: { restoreResult.map(RestoreAlert.init) },
            set: { if $0 == nil { restoreResult = nil } })
    }
}

/// A selectable product row with price, period and trial.
private struct ProductOption: View {
    let product: StoreProduct
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text(title).font(.headline)
                    Text(PaywallCopy.priceLine(for: product))
                    if let offer = product.activeIntroductoryOffer, offer.paymentMode == .freeTrial {
                        Text("Includes a \(offer.period.adjectiveDescription) free trial")
                            .font(.footnote)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.textSecondary.opacity(0.4), lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("paywall.product.\(product.id.rawValue)")
    }

    private var title: String {
        switch product.id {
        case .yearly: String(localized: "Yearly")
        case .monthly: String(localized: "Monthly")
        case .lifetime: String(localized: "Lifetime")
        }
    }
}

/// Everything Pro includes.
private struct FeatureList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(ProFeature.allCases) { feature in
                Label(feature.title, systemImage: feature.systemImage)
            }
            Text(
                "Free includes \(FreeTierLimits.collections) collection with up to \(FreeTierLimits.requestsPerCollection) requests, environments, secrets, history of \(FreeTierLimits.historyEntries) requests and cURL import."
            )
            .font(.footnote)
            .foregroundStyle(Color.textSecondary)
        }
    }
}

/// Opens subscription management: the system sheet on iOS, the App Store account page on macOS.
struct ManageSubscriptionButton: View {
    let source: EntitlementSource
    @State private var isManaging = false

    var body: some View {
        if case .subscription = source {
            #if os(iOS)
                Button("Manage Subscription") { isManaging = true }
                    .manageSubscriptionsSheet(isPresented: $isManaging)
                    .accessibilityIdentifier("store.manage")
            #else
                Link("Manage Subscription", destination: AppConstants.manageSubscriptionsURL)
                    .accessibilityIdentifier("store.manage")
            #endif
        }
    }
}

struct RestoreAlert: Identifiable {
    let result: EntitlementManager.RestoreResult
    var id: String { title }

    var title: String {
        switch result {
        case .restored: String(localized: "Purchases Restored")
        case .nothingToRestore: String(localized: "Nothing to Restore")
        case .failed(let error): error.errorDescription ?? String(localized: "Purchases Couldn't Be Restored")
        }
    }

    var message: String {
        switch result {
        case .restored: String(localized: "RequestPad Pro is active.")
        case .nothingToRestore:
            String(localized: "No RequestPad Pro purchase was found for this Apple Account.")
        case .failed(let error): error.recoverySuggestion ?? ""
        }
    }
}

/// Presents the paywall for `app.requestedProFeature` from the topmost presenter (the root view, or a sheet
/// that registered itself), so Pro prompts inside sheets are not lost on iOS.
struct PaywallPresenter: ViewModifier {
    let app: AppModel
    /// 0 for the root view, 1 for sheets.
    let level: Int

    func body(content: Content) -> some View {
        content
            .sheet(item: binding) { feature in
                PaywallView(app: app, feature: feature)
            }
            .onAppear { if level > 0 { app.presentationLevel = level } }
            .onDisappear { if level > 0 { app.presentationLevel = level - 1 } }
    }

    private var binding: Binding<ProFeature?> {
        Binding(
            get: { app.presentationLevel == level ? app.requestedProFeature : nil },
            set: { if $0 == nil { app.requestedProFeature = nil } })
    }
}

extension View {
    func presentsPaywall(_ app: AppModel, level: Int) -> some View {
        modifier(PaywallPresenter(app: app, level: level))
    }
}
