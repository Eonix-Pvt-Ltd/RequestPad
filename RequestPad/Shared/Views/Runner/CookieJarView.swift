import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

/// Browse and delete stored cookies (P07.2).
struct CookieJarView: View {
    let app: AppModel
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var jar: CookieJar?
    @State private var isClearConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if let jar {
                    if jar.cookies.isEmpty {
                        EmptyStateView(
                            "No Cookies", message: "Cookies set by responses appear here.", systemImage: "birthday.cake"
                        )
                        .accessibilityIdentifier("cookies.empty")
                    } else {
                        list(jar)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Cookies")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete All", role: .destructive) { isClearConfirmationPresented = true }
                        .disabled(jar?.cookies.isEmpty ?? true)
                        .accessibilityIdentifier("cookies.deleteAll")
                }
            }
            .confirmationDialog(
                "Delete all cookies?", isPresented: $isClearConfirmationPresented, titleVisibility: .visible
            ) {
                Button("Delete All Cookies", role: .destructive) { remove { _ in true } }
            }
            .task { jar = await app.cookieJar() }
        }
        .sheetFrame(minWidth: 520, minHeight: 480)
    }

    private func list(_ jar: CookieJar) -> some View {
        List {
            ForEach(jar.domains, id: \.self) { domain in
                Section {
                    ForEach(jar.cookies.filter { $0.domain == domain }) { cookie in
                        CookieRow(cookie: cookie)
                            .swipeActions {
                                Button("Delete", role: .destructive) { remove { $0.id == cookie.id } }
                            }
                            .contextMenu {
                                Button("Copy Value") { Clipboard.copy(cookie.value) }
                                Button("Delete", role: .destructive) { remove { $0.id == cookie.id } }
                            }
                    }
                } header: {
                    HStack {
                        Text(verbatim: domain)
                        Spacer()
                        Button("Delete Domain", role: .destructive) { remove { $0.domain == domain } }
                            .foregroundStyle(Color.textRed)
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .accessibilityIdentifier("cookies.list")
    }

    private func remove(where shouldRemove: @escaping @Sendable (Cookie) -> Bool) {
        Task { jar = await app.removeCookies(where: shouldRemove) }
    }
}

private struct CookieRow: View {
    let cookie: Cookie

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text(verbatim: "\(cookie.name)=\(cookie.value)")
                .font(.callout.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: Spacing.small) {
                Text(verbatim: cookie.path)
                if let expires = cookie.expiresAt {
                    Text("Expires \(expires.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Session")
                }
                if cookie.isSecure { Text("Secure") }
                if cookie.isHTTPOnly { Text("HttpOnly") }
            }
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
