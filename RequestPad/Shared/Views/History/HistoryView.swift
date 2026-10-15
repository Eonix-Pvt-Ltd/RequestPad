import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

/// Recent requests, searchable, re-openable as unsaved requests (F06).
struct HistoryView: View {
    let app: AppModel
    let workspace: WorkspaceModel
    @State private var query = ""
    @State private var isClearConfirmationPresented = false

    var body: some View {
        Group {
            if app.history.isEmpty {
                EmptyStateView("No History", message: "Requests you send appear here.", systemImage: "clock")
                    .accessibilityIdentifier("history.empty")
            } else if filtered.isEmpty {
                EmptyStateView("No Results", message: "No requests match “\(query)”.", systemImage: "magnifyingglass")
            } else {
                List {
                    ForEach(groups, id: \.day) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                Button {
                                    workspace.openScratch(entry.request)
                                } label: {
                                    HistoryRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open") { workspace.openScratch(entry.request) }
                                    Button("Delete", role: .destructive) {
                                        Task { await app.deleteHistoryEntry(entry.id) }
                                    }
                                }
                                .swipeActions {
                                    Button("Delete", role: .destructive) {
                                        Task { await app.deleteHistoryEntry(entry.id) }
                                    }
                                }
                            }
                        } header: {
                            Text(group.day.formatted(date: .complete, time: .omitted))
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    Section {
                        Button("Clear History…", role: .destructive) { isClearConfirmationPresented = true }
                            .foregroundStyle(Color.textRed)
                            .accessibilityIdentifier("history.clear")
                    } footer: {
                        Text(limitFooter)
                            .foregroundStyle(Color.textSecondary)
                            // macOS list footers are one line unless allowed to grow.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("history.list")
            }
        }
        .navigationTitle("History")
        .searchable(text: $query, prompt: "Search URL or name")
        .confirmationDialog("Clear all history?", isPresented: $isClearConfirmationPresented, titleVisibility: .visible)
        {
            Button("Clear History", role: .destructive) { Task { await app.clearHistory() } }
        } message: {
            Text("This can't be undone.")
        }
        .task { await app.reloadHistory() }
    }

    private var filtered: [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return app.history }
        return app.history.filter {
            $0.request.url.localizedCaseInsensitiveContains(trimmed)
                || $0.request.name.localizedCaseInsensitiveContains(trimmed)
                || $0.request.method.rawValue.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var groups: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.sentAt) }
        return grouped.keys.sorted(by: >).map { day in (day, grouped[day, default: []].sorted { $0.sentAt > $1.sentAt })
        }
    }

    private var limitFooter: String {
        String(localized: "RequestPad keeps your last \(HistoryLimits.entries) requests on this device.")
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xSmall))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.small))
        layout {
            MethodBadge(entry.request.method)
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(verbatim: entry.request.url)
                    .font(.callout.monospaced())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .truncationMode(.middle)
                metadataLayout {
                    if let code = entry.response.statusCode {
                        Text(verbatim: "\(code)")
                            .foregroundStyle(StatusBadgeStyle(statusClass: HTTPStatusClass(statusCode: code)).tint)
                    } else if let error = entry.response.errorSummary {
                        Text(error).foregroundStyle(Color.textRed).lineLimit(1)
                    }
                    Text(DurationFormat.string(milliseconds: Double(entry.response.durationMilliseconds)))
                    Text(entry.sentAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the request"))
    }

    /// Status, duration and time side by side, or stacked at accessibility text sizes.
    private var metadataLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: Spacing.small))
    }
}
