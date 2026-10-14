import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

/// Response pane: waiting, error or the response with body, headers, cookies, timeline and tests (F02).
struct ResponseView: View {
    let editor: RequestEditorModel

    var body: some View {
        switch editor.sendState {
        case .idle where editor.result == nil:
            EmptyStateView(
                "No Response Yet", message: "Send the request to see the response here.",
                systemImage: "arrow.down.circle"
            )
            .accessibilityIdentifier("response.empty")
        case .sending(let startedAt):
            SendingView(startedAt: startedAt) { editor.cancel() }
        case .failed(let error):
            EmptyStateView(
                LocalizedStringKey(error.title), message: LocalizedStringKey(error.message),
                systemImage: "wifi.exclamationmark"
            ) {
                Button("Try Again") { editor.send() }
                    .prominentButtonStyle()
                    .accessibilityIdentifier("response.retry")
            }
            .accessibilityIdentifier("response.error")
        case .idle, .finished:
            if let result = editor.result {
                ResponseDetail(result: result, app: editor.app)
                    .id(result.response.receivedAt)
            }
        }
    }
}

/// Elapsed time and Cancel while a request is in flight (F01.5).
private struct SendingView: View {
    let startedAt: Date
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Spacing.medium) {
            ProgressView()
            TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                Text(DurationFormat.string(milliseconds: context.date.timeIntervalSince(startedAt) * 1000))
                    .font(.title3.monospacedDigit())
                    .accessibilityLabel(Text("Sending"))
            }
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("response.sending")
    }
}

private struct ResponseDetail: View {
    enum Tab: String, CaseIterable, Identifiable {
        case body, headers, cookies, timeline, tests
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .body: "Body"
            case .headers: "Headers"
            case .cookies: "Cookies"
            case .timeline: "Timeline"
            case .tests: "Tests"
            }
        }
    }

    let result: SendResult
    let app: AppModel
    @SceneStorage("response.tab") private var tab: Tab = .body
    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.small)
            sectionPicker
                .labelsHidden()
                .padding(.horizontal, Spacing.medium)
                .padding(.bottom, Spacing.small)
                .accessibilityIdentifier("response.tabs")
            Divider()
            switch tab {
            case .body: ResponseBodyView(response: result.response)
            case .headers: HeadersList(headers: result.response.headers)
            case .cookies: CookiesList(setCookieHeaders: result.response.setCookieHeaders)
            case .timeline: TimelineList(response: result.response)
            case .tests: TestsList(result: result)
            }
        }
    }

    /// Segmented normally; a menu at accessibility text sizes, where segments would truncate.
    @ViewBuilder private var sectionPicker: some View {
        let picker = Picker("Section", selection: $tab) {
            ForEach(Tab.allCases) { item in
                Text(title(for: item)).tag(item)
            }
        }
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private func title(for item: Tab) -> String {
        switch item {
        case .headers: String(localized: "Headers (\(result.response.headers.count))")
        case .cookies: String(localized: "Cookies (\(result.response.setCookieHeaders.count))")
        case .tests:
            result.assertions.isEmpty
                ? String(localized: "Tests")
                : String(localized: "Tests (\(result.assertions.filter(\.didPass).count)/\(result.assertions.count))")
        case .body: String(localized: "Body")
        case .timeline: String(localized: "Timeline")
        }
    }

    private var summary: some View {
        let response = result.response
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.medium) { summaryItems(response) }
            VStack(alignment: .leading, spacing: Spacing.xSmall) { summaryItems(response) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("response.summary")
    }

    @ViewBuilder private func summaryItems(_ response: HTTPResponse) -> some View {
        StatusBadge(code: response.statusCode, reason: response.reasonPhrase)
            .accessibilityIdentifier("response.status")
        if let total = response.timings?.total {
            Label(DurationFormat.string(milliseconds: total), systemImage: "clock")
                .accessibilityLabel(Text("Time \(DurationFormat.string(milliseconds: total))"))
        }
        Label(ByteFormat.string(response.body.size), systemImage: "arrow.down.doc")
            .accessibilityLabel(Text("Size \(ByteFormat.string(response.body.size))"))
        if !response.redirects.isEmpty {
            Label("\(response.redirects.count) redirects", systemImage: "arrow.triangle.turn.up.right.diamond")
        }
    }
}

private struct HeadersList: View {
    let headers: [(name: String, value: String)]

    var body: some View {
        List {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text(verbatim: header.name).font(.callout.monospaced().weight(.semibold))
                    Text(verbatim: header.value).font(.callout.monospaced()).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .contextMenu {
                    Button("Copy Value") { Clipboard.copy(header.value) }
                    Button("Copy Header") { Clipboard.copy("\(header.name): \(header.value)") }
                }
            }
        }
        .accessibilityIdentifier("response.headers")
    }
}

private struct CookiesList: View {
    let setCookieHeaders: [String]

    var body: some View {
        if setCookieHeaders.isEmpty {
            EmptyStateView("No Cookies", message: "The response didn't set any cookies.", systemImage: "birthday.cake")
        } else {
            List(setCookieHeaders, id: \.self) { header in
                Text(verbatim: header)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

private struct TimelineList: View {
    let response: HTTPResponse

    var body: some View {
        List {
            if let timings = response.timings {
                Section {
                    row("DNS Lookup", timings.dnsLookup)
                    row("TCP Connect", timings.tcpConnect)
                    row("TLS Handshake", timings.tlsHandshake)
                    row("Request Sent", timings.requestSend)
                    row("Waiting (TTFB)", timings.waiting)
                    row("Download", timings.download)
                    row("Total", timings.total)
                    if timings.isReusedConnection {
                        Text("Reused an existing connection.").foregroundStyle(Color.textSecondary)
                    }
                } header: {
                    SectionHeader("Timing")
                }
            }
            Section {
                LabeledContent("URL") { Text(verbatim: response.url.absoluteString).textSelection(.enabled) }
                if let networkProtocol = response.networkProtocol { LabeledContent("Protocol", value: networkProtocol) }
                if let address = response.remoteAddress { LabeledContent("Remote Address", value: address) }
                if let tls = response.tlsVersion { LabeledContent("TLS", value: tls) }
                if let cipher = response.tlsCipherSuite { LabeledContent("Cipher Suite", value: cipher) }
                LabeledContent("Headers Size", value: ByteFormat.string(response.headerBytes))
                LabeledContent("Body Size", value: ByteFormat.string(response.body.size))
            } header: {
                SectionHeader("Connection")
            }
            if !response.redirects.isEmpty {
                Section {
                    ForEach(Array(response.redirects.enumerated()), id: \.offset) { _, hop in
                        VStack(alignment: .leading) {
                            Text(verbatim: "\(hop.statusCode) → \(hop.to.absoluteString)").font(.callout.monospaced())
                            Text(verbatim: hop.from.absoluteString).font(.caption.monospaced()).foregroundStyle(
                                Color.textSecondary)
                        }
                    }
                } header: {
                    SectionHeader("Redirects")
                }
            }
        }
        .accessibilityIdentifier("response.timeline")
    }

    @ViewBuilder private func row(_ title: LocalizedStringKey, _ milliseconds: Double?) -> some View {
        if let milliseconds {
            LabeledContent(title, value: DurationFormat.string(milliseconds: milliseconds))
        }
    }
}

/// Assertion and extraction results (P05, P06).
private struct TestsList: View {
    let result: SendResult

    var body: some View {
        if result.assertions.isEmpty && result.extractions.isEmpty {
            EmptyStateView(
                "No Tests", message: "Add assertions or extraction rules in the request's Assert and Extract tabs.",
                systemImage: "checkmark.seal")
        } else {
            List {
                if !result.assertions.isEmpty {
                    Section {
                        ForEach(Array(result.assertions.enumerated()), id: \.offset) { _, assertion in
                            assertionRow(assertion)
                        }
                    } header: {
                        SectionHeader("Assertions")
                    }
                }
                if !result.extractions.isEmpty {
                    Section {
                        ForEach(Array(result.extractions.enumerated()), id: \.offset) { _, extraction in
                            extractionRow(extraction)
                        }
                    } header: {
                        SectionHeader("Extracted Variables")
                    }
                }
            }
            .accessibilityIdentifier("response.tests")
        }
    }

    private func assertionRow(_ assertion: AssertionResult) -> some View {
        let (symbol, tint, detail): (String, Color, String?) =
            switch assertion.outcome {
            case .passed: ("checkmark.circle.fill", .textGreen, nil)
            case .failed(let message): ("xmark.circle.fill", .textRed, message)
            case .skipped(let message): ("minus.circle", .textSecondary, message)
            }
        return Label {
            VStack(alignment: .leading) {
                Text(verbatim: "\(assertion.assertion.rawKey) \(assertion.assertion.rawValue)").font(
                    .callout.monospaced())
                if let detail { Text(detail).font(.caption).foregroundStyle(Color.textSecondary) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private func extractionRow(_ extraction: ExtractionResult) -> some View {
        LabeledContent {
            switch extraction.outcome {
            case .extracted(let value):
                Text(verbatim: value).font(.callout.monospaced()).lineLimit(2).textSelection(.enabled)
            case .notFound: Text("Not found").foregroundStyle(Color.textOrange)
            case .failed(let message): Text(message).foregroundStyle(Color.textRed)
            }
        } label: {
            Text(verbatim: "{{\(extraction.variableName)}}").font(.callout.monospaced())
        }
    }
}
