import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI

/// Explains which feature needs Pro and lists everything Pro includes (PRD §4).
/// Purchase options are added with StoreKit in Phase 5.
struct ProUpsellView: View {
    let app: AppModel
    let feature: ProFeature
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Label(feature.title, systemImage: feature.systemImage)
                            .font(.title3.bold())
                        Text("This is part of RequestPad Pro.")
                            .foregroundStyle(Color.textSecondary)
                    }
                    .padding(.vertical, Spacing.xSmall)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pro.feature")
                }
                Section {
                    ForEach(ProFeature.allCases) { item in
                        Label(item.title, systemImage: item.systemImage)
                    }
                } header: {
                    SectionHeader("Everything in Pro")
                }
                Section {
                    Text(
                        "Free includes \(FreeTierLimits.collections) collections with up to \(FreeTierLimits.requestsPerCollection) requests each, environments, secrets, history of \(FreeTierLimits.historyLimit(isPro: false)) requests and cURL import."
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                }
            }
            .navigationTitle("RequestPad Pro")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                        .accessibilityIdentifier("pro.close")
                }
            }
        }
        .frame(minWidth: 440, minHeight: 520)
    }
}
