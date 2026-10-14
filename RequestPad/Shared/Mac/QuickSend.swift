#if os(macOS)
    import Observation
    import RPCore
    import RPServices
    import RPUI
    import SwiftUI

    /// Menu bar Quick Send state (P09.1): a saved request or a typed URL, an environment, and the last result.
    @Observable
    final class QuickSendModel {
        enum Source: Hashable {
            case url
            case saved(String)
        }

        enum State: Equatable {
            case idle
            case sending
            case finished(QuickSendResult)
            case failed(String)
        }

        /// Bodies shown in the popover are cut to this size (the app shows the whole response).
        static let previewBytes = 64 * 1024

        let app: AppModel
        var source: Source = .url
        var urlText = ""
        var environment: EnvironmentChoice = .active
        private(set) var state: State = .idle
        private var task: Task<Void, Never>?

        init(app: AppModel) {
            self.app = app
        }

        var savedRequests: [SavedRequestSummary] { app.savedRequests() }

        var selectedRequest: SavedRequestSummary? {
            guard case .saved(let id) = source else { return nil }
            return savedRequests.first { $0.id == id }
        }

        var canSend: Bool {
            guard state != .sending else { return false }
            switch source {
            case .url: return SharedURL.url(from: urlText) != nil
            case .saved: return selectedRequest != nil
            }
        }

        func send() {
            guard canSend else { return }
            let reference = selectedRequest?.reference
            let request: RequestItem
            if let saved = selectedRequest {
                request = saved.request
            } else if let url = SharedURL.url(from: urlText) {
                request = RequestItem(name: SharedURL.requestName(for: url), url: url)
            } else {
                return
            }
            let choice = reference == nil ? EnvironmentChoice.active : environment
            state = .sending
            task = Task {
                do throws(SendError) {
                    let result = try await app.send(request, reference: reference, environment: choice)
                    let content = await ResponseContent.load(from: result.response)
                    state = .finished(QuickSendResult(result: result, content: content))
                } catch {
                    if case .network(.cancelled) = error {
                        state = .idle
                    } else {
                        state = .failed(PresentedError(error).title)
                    }
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }

        /// "Open in RequestPad": the saved request, or the typed URL as an unsaved request.
        func openInApp() {
            if let saved = selectedRequest {
                AppRuntime.shared.show(.request(saved.reference), in: app)
            } else if let url = SharedURL.url(from: urlText) {
                AppRuntime.shared.show(.scratch(RequestItem(name: SharedURL.requestName(for: url), url: url)), in: app)
            }
        }
    }

    /// Saved requests of one collection, for the picker.
    struct RequestGroup: Identifiable {
        var id: UUID
        var name: String
        var requests: [SavedRequestSummary]
    }

    struct QuickSendResult: Equatable {
        var statusCode: Int
        var reasonPhrase: String
        var durationMilliseconds: Int
        var sizeBytes: Int
        var bodyPreview: String
        var isTruncated: Bool

        init(result: SendResult, content: ResponseContent) {
            statusCode = result.response.statusCode
            reasonPhrase = result.response.reasonPhrase
            durationMilliseconds = Int(result.response.timings?.total ?? 0)
            sizeBytes = result.response.body.size
            let text =
                content.kind == .image || content.kind == .binary
                ? String(localized: "\(ByteFormat.string(sizeBytes)) of binary data. Open in RequestPad to save it.")
                : content.text
            let limited = String(decoding: Data(text.utf8).prefix(QuickSendModel.previewBytes), as: UTF8.self)
            bodyPreview = limited
            isTruncated = limited.utf8.count < text.utf8.count || content.isTruncated
        }
    }

    /// The menu bar popover (P09.1). Kept light so it opens quickly (P09.2): it reads the already-loaded collections.
    struct QuickSendView: View {
        @State private var model: QuickSendModel
        private var app: AppModel { model.app }

        init(app: AppModel) {
            _model = State(initialValue: QuickSendModel(app: app))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.small) {
                form
                resultView
            }
            .padding(Spacing.medium)
            .frame(width: 380)
            .task { await app.load() }
        }

        @ViewBuilder private var form: some View {
            @Bindable var model = model
            Picker("Request", selection: $model.source) {
                Text("Type a URL").tag(QuickSendModel.Source.url)
                ForEach(groupedRequests) { group in
                    Section(group.name) {
                        ForEach(group.requests) { saved in
                            Text(verbatim: "\(saved.request.method.rawValue) \(saved.request.name)")
                                .tag(QuickSendModel.Source.saved(saved.id))
                        }
                    }
                }
            }
            .accessibilityIdentifier("quickSend.source")
            .onChange(of: model.source) { _, _ in model.environment = .active }
            if model.source == .url {
                TextField("https://api.example.com/status", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .monospacedField()
                    .onSubmit { model.send() }
                    .accessibilityLabel(Text("URL"))
                    .accessibilityIdentifier("quickSend.url")
            } else if let selected = model.selectedRequest {
                Picker("Environment", selection: $model.environment) {
                    let active = app.activeEnvironment(for: selected.reference.collectionID)?.environment.name
                    Text(active.map { String(localized: "Active (\($0))") } ?? String(localized: "Active (none)"))
                        .tag(EnvironmentChoice.active)
                    Text("No Environment").tag(EnvironmentChoice.none)
                    ForEach(app.environments(for: selected.reference.collectionID)) { entry in
                        Text(entry.environment.name).tag(EnvironmentChoice.key(entry.key))
                    }
                }
                .accessibilityIdentifier("quickSend.environment")
            }
            HStack {
                if model.state == .sending {
                    Button("Cancel", role: .cancel) { model.cancel() }
                } else {
                    Button("Send") { model.send() }
                        .prominentButtonStyle()
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canSend)
                        .accessibilityIdentifier("quickSend.send")
                }
                Spacer()
                Button("Open in RequestPad") { model.openInApp() }
                    .disabled(model.source == .url && SharedURL.url(from: model.urlText) == nil)
                    .accessibilityIdentifier("quickSend.open")
            }
        }

        @ViewBuilder private var resultView: some View {
            switch model.state {
            case .idle:
                EmptyView()
            case .sending:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.textOrange)
                    .accessibilityIdentifier("quickSend.error")
            case .finished(let result):
                Divider()
                HStack {
                    StatusBadge(code: result.statusCode, reason: result.reasonPhrase)
                    Spacer()
                    Text(DurationFormat.string(milliseconds: Double(result.durationMilliseconds)))
                    Text(ByteFormat.string(result.sizeBytes))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("quickSend.status")
                ScrollView {
                    Text(verbatim: result.bodyPreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                if result.isTruncated {
                    Text("Showing the first 64 KB. Open in RequestPad for the full response.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }

        private var groupedRequests: [RequestGroup] {
            var groups: [RequestGroup] = []
            for saved in model.savedRequests {
                if let index = groups.firstIndex(where: { $0.id == saved.reference.collectionID }) {
                    groups[index].requests.append(saved)
                } else {
                    groups.append(
                        RequestGroup(id: saved.reference.collectionID, name: saved.collectionName, requests: [saved]))
                }
            }
            return groups
        }
    }
#endif
