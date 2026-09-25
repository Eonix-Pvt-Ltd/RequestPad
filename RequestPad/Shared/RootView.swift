import RPUI
import SwiftUI

/// Top-level navigation. Shows a recoverable error if launch preparation failed.
struct RootView: View {
    let launch: LaunchModel

    var body: some View {
        switch launch.state {
        case .ready:
            NavigationSplitView {
                List {
                    Label("No Collections Yet", systemImage: "tray")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("root.sidebar.empty")
                }
                .navigationTitle("RequestPad")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                EmptyStateView(
                    "No Request Selected", message: "Select a request to edit and send it.",
                    systemImage: "paperplane"
                )
                .accessibilityIdentifier("root.detail.empty")
            }
        case .failed(let error):
            EmptyStateView(
                "RequestPad Couldn't Start",
                message: "\(error.errorDescription ?? "")\n\(error.recoverySuggestion ?? "")",
                systemImage: "exclamationmark.triangle"
            ) {
                Button("Try Again") { launch.retry() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("root.retry")
            }
        }
    }
}
