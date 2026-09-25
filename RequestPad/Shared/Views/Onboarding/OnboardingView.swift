import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI

/// Three skippable screens on first launch; the last offers sample data (X02.1).
struct OnboardingView: View {
    private struct Page: Identifiable {
        let id: Int
        let systemImage: String
        let title: LocalizedStringKey
        let message: LocalizedStringKey
    }

    private static let pages = [
        Page(
            id: 0, systemImage: "paperplane.circle.fill", title: "Welcome to RequestPad",
            message:
                "Build and send HTTP requests on iPhone, iPad and Mac. No account, no tracking — your data stays on your device."
        ),
        Page(
            id: 1, systemImage: "folder.badge.gearshape", title: "Organize with Collections",
            message:
                "Group requests into collections and folders, switch environments, and keep secrets in the Keychain."),
        Page(
            id: 2, systemImage: "sparkles", title: "Try It Right Away",
            message:
                "Load sample requests that talk to a small echo server running inside RequestPad — no internet needed."),
    ]

    let app: AppModel
    @State private var index = 0
    @State private var isLoading = false
    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: Spacing.large) {
            HStack {
                Spacer()
                Button("Skip") { app.completeOnboarding() }
                    .accessibilityIdentifier("onboarding.skip")
            }
            let page = Self.pages[index]
            // Scrolls at large accessibility text sizes so the buttons below stay on screen.
            ScrollView {
                VStack(spacing: Spacing.medium) {
                    Image(systemName: page.systemImage)
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(page.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue(Text("Page \(index + 1) of \(Self.pages.count)"))
                    Text(page.message)
                        .font(.title3)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                }
                .frame(maxWidth: .infinity)
                .id(page.id)
                .transition(.opacity)
            }
            .defaultScrollAnchor(.center)
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: Spacing.xSmall) {
                ForEach(Self.pages) { item in
                    Circle()
                        .fill(item.id == index ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
            buttons
        }
        .padding(Spacing.xLarge)
        .animation(.default, value: index)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var buttons: some View {
        if index < Self.pages.count - 1 {
            // Stacked at accessibility text sizes so neither button wraps into the page text.
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout()) : AnyLayout(HStackLayout())
            layout {
                if index > 0 {
                    Button("Back") { index -= 1 }
                        .buttonStyle(.bordered)
                }
                Button("Continue") { index += 1 }
                    .prominentButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.continue")
            }
            .controlSize(.large)
        } else {
            VStack(spacing: Spacing.small) {
                Button {
                    isLoading = true
                    Task {
                        await app.loadSampleData()
                        isLoading = false
                        app.completeOnboarding()
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Load Sample Data")
                    }
                }
                .prominentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading)
                .accessibilityIdentifier("onboarding.loadSample")
                Button("Start Empty") { app.completeOnboarding() }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                    .accessibilityIdentifier("onboarding.startEmpty")
            }
            .controlSize(.large)
        }
    }
}
