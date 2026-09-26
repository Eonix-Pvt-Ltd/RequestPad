import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI
import UniformTypeIdentifiers

/// Runs a collection or folder in order and reports assertion results (P06.2, P06.3).
struct RunnerView: View {
    let app: AppModel
    let collectionID: UUID
    let folderKey: String?
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var items: [RunItem] = []
    @State private var excluded: Set<Int> = []
    @State private var stopOnFailure = false
    @State private var results: [Int: RunItemResult] = [:]
    @State private var runningIndex: Int?
    @State private var report: RunReport?
    @State private var runTask: Task<Void, Never>?
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Stop on First Failure", isOn: $stopOnFailure)
                        .disabled(isRunning)
                    if let report {
                        summary(report)
                    }
                }
                Section {
                    if items.isEmpty {
                        Text("There are no requests to run.").foregroundStyle(Color.textSecondary)
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        row(index: index, item: item)
                    }
                } header: {
                    SectionHeader("Requests")
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        runTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isRunning {
                        Button("Stop") { runTask?.cancel() }
                            .accessibilityIdentifier("runner.stop")
                    } else {
                        Button("Run") { run() }
                            .disabled(items.count == excluded.count)
                            .accessibilityIdentifier("runner.run")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Export Results…") { isExporting = true }
                        .disabled(report == nil)
                        .accessibilityIdentifier("runner.export")
                }
            }
            .fileExporter(
                isPresented: $isExporting, document: report.map(RunReportDocument.init(report:)), contentType: .json,
                defaultFilename: "run-report"
            ) { result in
                if case .failure(let error) = result {
                    app.presentedError = PresentedError(ExportFailure(reason: error.localizedDescription))
                }
            }
            .onAppear {
                items = app.runItems(collectionID: collectionID, folderKey: folderKey)
                if app.runnerAutoStart {
                    app.runnerAutoStart = false
                    run()
                }
            }
        }
        .sheetFrame(minWidth: 560, minHeight: 520)
    }

    private var isRunning: Bool { runTask != nil }

    private var title: String {
        let tree = app.collection(collectionID)?.tree
        if let folderKey, let folder = tree?.folders.first(where: { $0.key == folderKey }) {
            return String(localized: "Run \(folder.name)")
        }
        return String(localized: "Run \(tree?.name ?? "")")
    }

    private func row(index: Int, item: RunItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Toggle(
                isOn: Binding(
                    get: { !excluded.contains(index) },
                    set: { if $0 { excluded.remove(index) } else { excluded.insert(index) } })
            ) {
                Text("Include \(item.request.name)")
            }
            .labelsHidden()
            .toggleStyle(.checkboxCompat)
            .disabled(isRunning)
            MethodBadge(item.request.method).frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(verbatim: item.displayPath)
                if let result = results[index] {
                    resultDetail(result)
                }
            }
            Spacer()
            status(index: index)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func status(index: Int) -> some View {
        if runningIndex == index {
            ProgressView().controlSize(.small).accessibilityLabel(Text("Running"))
        } else if let result = results[index] {
            switch result.outcome {
            case .passed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.textGreen).accessibilityLabel(
                    Text("Passed"))
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textRed).accessibilityLabel(Text("Failed"))
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.textOrange).accessibilityLabel(
                    Text("Error"))
            case .skipped:
                Image(systemName: "minus.circle").foregroundStyle(Color.textSecondary).accessibilityLabel(
                    Text("Skipped"))
            }
        }
    }

    @ViewBuilder private func resultDetail(_ result: RunItemResult) -> some View {
        HStack(spacing: Spacing.small) {
            if let code = result.statusCode { Text(verbatim: "\(code)") }
            Text(DurationFormat.string(milliseconds: Double(result.durationMilliseconds)))
            if !result.assertionResults.isEmpty {
                Text(
                    "\(result.assertionResults.filter { $0.passed == true }.count)/\(result.assertionResults.count) assertions passed"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(Color.textSecondary)
        if let message = result.errorMessage {
            Text(message).font(.caption).foregroundStyle(Color.textOrange)
        }
        ForEach(Array(result.assertionResults.filter { $0.passed == false }.enumerated()), id: \.offset) { _, failure in
            Text(verbatim: "✗ \(failure.expression)\(failure.message.map { " — \($0)" } ?? "")")
                .font(.caption.monospaced())
                .foregroundStyle(Color.textRed)
        }
    }

    private func summary(_ report: RunReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("\(report.passedCount) passed, \(report.failedCount) failed")
                .font(.headline)
            if report.wasCancelled {
                Text("The run was stopped.").foregroundStyle(Color.textSecondary)
            } else if report.stoppedOnFailure {
                Text("Stopped at the first failure.").foregroundStyle(Color.textSecondary)
            }
            Text(DurationFormat.string(milliseconds: report.finishedAt.timeIntervalSince(report.startedAt) * 1000))
                .foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("runner.summary")
    }

    private func run() {
        let selected = items.enumerated().filter { !excluded.contains($0.offset) }
        let indices = selected.map(\.offset)
        results = [:]
        report = nil
        let stream = app.run(selected.map(\.element), collectionID: collectionID, stopOnFailure: stopOnFailure)
        runTask = Task {
            for await event in stream {
                switch event {
                case .started(let position, _): runningIndex = indices[position]
                case .finished(let position, let result):
                    results[indices[position]] = result
                    runningIndex = nil
                case .completed(let finished): report = finished
                }
            }
            runningIndex = nil
            runTask = nil
        }
    }
}

private struct ExportFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { String(localized: "The results couldn't be exported.") }
    var recoverySuggestion: String? { reason }
}

/// The run report as JSON (P06.3).
struct RunReportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(report: RunReport) {
        data = (try? report.jsonData()) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
