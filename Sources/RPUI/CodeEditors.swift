import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Editable monospaced text for request bodies and GraphQL (no smart quotes or autocorrection).
public struct CodeEditor: View {
    @Binding var text: String
    let label: LocalizedStringKey
    let identifier: String
    let isReadOnly: Bool

    public init(text: Binding<String>, label: LocalizedStringKey, identifier: String, isReadOnly: Bool = false) {
        _text = text
        self.label = label
        self.identifier = identifier
        self.isReadOnly = isReadOnly
    }

    public var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            .scrollContentBackground(.hidden)
            .padding(Spacing.xSmall)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 120)
            .disabled(isReadOnly)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(identifier)
    }
}

/// Read-only, selectable text for large response bodies. Backed by the platform text view, which lays out
/// lazily, so multi-megabyte bodies scroll smoothly (B1 allows bridging for very large documents).
public struct LargeTextView: View {
    let text: String
    let identifier: String

    public init(text: String, identifier: String) {
        self.text = text
        self.identifier = identifier
    }

    public var body: some View {
        PlatformTextView(text: text)
            .accessibilityLabel(Text("Response text"))
            .accessibilityIdentifier(identifier)
    }
}

#if os(iOS)
    struct PlatformTextView: UIViewRepresentable {
        let text: String

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.isEditable = false
            view.isSelectable = true
            view.adjustsFontForContentSizeCategory = true
            view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .monospacedSystemFont(ofSize: 14, weight: .regular))
            view.backgroundColor = .clear
            view.dataDetectorTypes = []
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            if view.text != text { view.text = text }
        }
    }
#else
    struct PlatformTextView: NSViewRepresentable {
        let text: String

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSTextView.scrollableTextView()
            if let textView = scrollView.documentView as? NSTextView {
                textView.isEditable = false
                textView.isSelectable = true
                textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                textView.drawsBackground = false
                textView.isAutomaticLinkDetectionEnabled = false
            }
            scrollView.drawsBackground = false
            return scrollView
        }

        func updateNSView(_ scrollView: NSScrollView, context: Context) {
            guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
            textView.string = text
        }
    }
#endif
