import RPCore
import RPData
import RPServices
import RPUI
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Plain-text clipboard access for both platforms.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// A banner with an icon, message and optional actions (conflicts, notices).
struct NoticeBanner<Actions: View>: View {
    let systemImage: String
    let message: Text
    let tint: Color
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            message
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .font(.callout)
        .padding(Spacing.small)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

extension NoticeBanner where Actions == EmptyView {
    init(systemImage: String, message: Text, tint: Color) {
        self.init(systemImage: systemImage, message: message, tint: tint) { EmptyView() }
    }
}

/// A secure text field with a show/hide button (passwords, client secrets).
struct RevealableField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let identifier: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: Spacing.xSmall) {
            Group {
                if isRevealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .monospacedField()
            .accessibilityIdentifier(identifier)
            Button {
                isRevealed.toggle()
            } label: {
                Label(isRevealed ? "Hide" : "Show", systemImage: isRevealed ? "eye.slash" : "eye")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .minimumHitTarget()
        }
    }
}

/// A labelled row for forms that also lay out well outside `Form` (editor tabs).
struct FieldRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            content
        }
    }
}

/// Byte counts for display ("1.2 MB").
enum ByteFormat {
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Milliseconds for display ("235 ms", "1.24 s").
enum DurationFormat {
    static func string(milliseconds: Double) -> String {
        milliseconds < 1000
            ? String(localized: "\(Int(milliseconds.rounded())) ms")
            : String(localized: "\((milliseconds / 1000).formatted(.number.precision(.fractionLength(2)))) s")
    }
}

extension View {
    /// `.borderedProminent` with a label color that keeps 4.5:1 contrast on the accent in light and dark mode
    /// (white on the dark light-mode accent, black on the bright dark-mode accent; ADR-0038).
    func prominentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .foregroundStyle(Color("OnAccent"))
    }
}

/// A Form/List section title in `Color.textSecondary`, which keeps 4.5:1 contrast where the system header color
/// does not (ADR-0038).
struct SectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .foregroundStyle(Color.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A minimum size for sheets on macOS, where sheets size to their content. iOS sheets fill the available width,
    /// and a minimum wider than an iPhone would push content off screen.
    func sheetFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
            frame(minWidth: minWidth, minHeight: minHeight)
        #else
            self
        #endif
    }
}
