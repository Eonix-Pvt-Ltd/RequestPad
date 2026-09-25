import RPCore
import RPData
import RPServices
import RPStore
import RPUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// A response body prepared off the main actor: decoded text, parsed JSON and the content kind (F02.2–F02.5).
nonisolated struct ResponseContent: Sendable {
    /// Bodies larger than this show a prefix as text (the whole body can still be saved to a file).
    static let previewBytes = 1024 * 1024

    var kind: ResponseContentKind
    var text: String
    var encodingName: String
    var isLossy: Bool
    var json: JSONValue?
    var imageData: Data?
    var isTruncated: Bool

    static func load(from response: HTTPResponse) async -> ResponseContent {
        await Task.detached(priority: .userInitiated) { make(response) }.value
    }

    private static func make(_ response: HTTPResponse) -> ResponseContent {
        let contentType = response.contentType
        let inMemory = response.body.inMemoryData
        let data = inMemory ?? response.body.prefix(previewBytes)
        let kind = ResponseContentKind.classify(contentType: contentType, prefix: data.prefix(512))
        let isTruncated = inMemory == nil || data.count > previewBytes
        let visible = isTruncated ? data.prefix(previewBytes) : data
        let decoded = BodyDecoder.decode(Data(visible), contentType: contentType)
        let json = kind == .json && !isTruncated ? try? JSONParser().parse(data) : nil
        return ResponseContent(
            kind: kind, text: kind == .binary ? hexDump(visible.prefix(4096)) : decoded.text,
            encodingName: decoded.encodingName,
            isLossy: decoded.isLossy, json: json, imageData: kind == .image && inMemory != nil ? data : nil,
            isTruncated: isTruncated)
    }

    private static func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[start..<min(start + 16, bytes.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(
                String(format: "%08x  ", start) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        return lines.joined(separator: "\n")
    }
}

/// Pretty (JSON tree with JSONPath filter), Raw and Preview (images) modes, copy and save.
struct ResponseBodyView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case pretty, raw, preview
        var id: String { rawValue }
    }

    let response: HTTPResponse
    @State private var content: ResponseContent?
    @State private var mode: Mode = .pretty
    @State private var filter = ""
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content {
                toolbar(content)
                    .padding(.horizontal, Spacing.medium)
                    .padding(.vertical, Spacing.xSmall)
                if content.isTruncated {
                    NoticeBanner(
                        systemImage: "doc.badge.ellipsis",
                        message: Text(
                            "Large response (\(ByteFormat.string(response.body.size))). Showing the first \(ByteFormat.string(ResponseContent.previewBytes)); save it to a file to see everything."
                        ),
                        tint: .textBlue
                    )
                    .padding(.horizontal, Spacing.medium)
                }
                if content.isLossy {
                    Text("Some bytes weren't valid \(content.encodingName) and are shown as �.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Spacing.medium)
                }
                bodyContent(content)
            } else {
                ProgressView("Preparing response…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let loaded = await ResponseContent.load(from: response)
            content = loaded
            mode = loaded.json != nil ? .pretty : (loaded.kind == .image ? .preview : .raw)
        }
        .fileExporter(
            isPresented: $isExporting, document: ResponseBodyDocument(body: response.body), contentType: .data,
            defaultFilename: suggestedFilename
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert(
            "Couldn't Save the Response",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func toolbar(_ content: ResponseContent) -> some View {
        HStack(spacing: Spacing.small) {
            Picker("View", selection: $mode) {
                if content.json != nil { Text("Pretty").tag(Mode.pretty) }
                Text("Raw").tag(Mode.raw)
                if content.imageData != nil { Text("Preview").tag(Mode.preview) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("response.body.mode")
            Spacer()
            Button {
                Clipboard.copy(content.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .minimumHitTarget()
            .disabled(content.kind == .binary || content.kind == .image)
            .accessibilityIdentifier("response.body.copy")
            Button {
                isExporting = true
            } label: {
                Label("Save to File", systemImage: "square.and.arrow.down")
            }
            .minimumHitTarget()
            .accessibilityIdentifier("response.body.save")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func bodyContent(_ content: ResponseContent) -> some View {
        switch mode {
        case .pretty:
            if let json = content.json {
                JSONFilterView(root: json, filter: $filter)
            } else {
                LargeTextView(text: content.text, identifier: "response.body.raw")
            }
        case .raw:
            if response.body.size == 0 {
                EmptyStateView("Empty Body", message: "The response has no body.", systemImage: "doc")
            } else {
                LargeTextView(text: content.text, identifier: "response.body.raw")
                if content.kind == .html {
                    Text("HTML is shown as source; RequestPad doesn't render web pages.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .padding(Spacing.small)
                }
            }
        case .preview:
            if let data = content.imageData, let image = PlatformImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 800)
                        .padding(Spacing.medium)
                        .accessibilityLabel(Text("Response image"))
                }
                .accessibilityIdentifier("response.body.image")
            } else {
                EmptyStateView(
                    "Preview Unavailable", message: "This image format can't be displayed.", systemImage: "photo")
            }
        }
    }

    private var suggestedFilename: String {
        let base =
            response.url.lastPathComponent.isEmpty || response.url.lastPathComponent == "/"
            ? "response" : response.url.lastPathComponent
        guard !base.contains("."),
            let type = response.contentType.flatMap({ UTType(mimeType: String($0.split(separator: ";")[0])) }),
            let ext = type.preferredFilenameExtension
        else { return base }
        return "\(base).\(ext)"
    }
}

/// JSON tree with a JSONPath filter (F02.4).
private struct JSONFilterView: View {
    let root: JSONValue
    @Binding var filter: String

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter with JSONPath, e.g. $.items[*].id", text: $filter)
                .textFieldStyle(.roundedBorder)
                .monospacedField()
                .padding(.horizontal, Spacing.medium)
                .padding(.bottom, Spacing.xSmall)
                .accessibilityIdentifier("response.body.filter")
            switch filtered {
            case .success(let value):
                JSONTreeView(root: value)
                    .accessibilityIdentifier("response.body.tree")
            case .failure(let error):
                Text(error.errorDescription ?? "")
                    .foregroundStyle(Color.textOrange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Spacing.medium)
            }
        }
    }

    private var filtered: Result<JSONValue, CoreError> {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "$" else { return .success(root) }
        do {
            let matches = try JSONPath(trimmed).evaluate(root)
            return .success(matches.count == 1 ? matches[0].value : .array(matches.map(\.value)))
        } catch {
            return .failure(error)
        }
    }
}

/// Writes a response body (in memory or spooled to disk) to a user-chosen file.
struct ResponseBodyDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let body: ResponseBodyStorage

    init(body: ResponseBodyStorage) {
        self.body = body
    }

    init(configuration: ReadConfiguration) throws {
        body = .memory(configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch body {
        case .memory(let data): FileWrapper(regularFileWithContents: data)
        case .file(let url, _): try FileWrapper(url: url, options: .immediate)
        }
    }
}

#if os(iOS)
    typealias PlatformImage = UIImage
    extension Image {
        init(platformImage: UIImage) { self.init(uiImage: platformImage) }
    }
#else
    typealias PlatformImage = NSImage
    extension Image {
        init(platformImage: NSImage) { self.init(nsImage: platformImage) }
    }
#endif
