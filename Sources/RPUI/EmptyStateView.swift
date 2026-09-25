import SwiftUI

/// Empty/error state used by lists and detail panes. The symbol is decorative and hidden from assistive
/// technologies; title and message are read as one element. An optional action offers recovery (retry, open…).
public struct EmptyStateView<Actions: View>: View {
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey
    private let systemImage: String
    private let actions: Actions

    public init(
        _ title: LocalizedStringKey, message: LocalizedStringKey, systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.xSmall) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.8))
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            actions
        }
        .padding(Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    public init(_ title: LocalizedStringKey, message: LocalizedStringKey, systemImage: String) {
        self.init(title, message: message, systemImage: systemImage) { EmptyView() }
    }
}
