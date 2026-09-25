import RPCore
import SwiftUI

/// HTTP method label with a per-method tint (text is always shown, so color is never the only signal).
public struct MethodBadge: View {
    let method: HTTPMethod
    /// `.increased` on a selected list row: the tint would sit on the accent highlight, so the row's own
    /// foreground is used instead.
    @SwiftUI.Environment(\.backgroundProminence) private var backgroundProminence

    public init(_ method: HTTPMethod) {
        self.method = method
    }

    public var body: some View {
        Text(verbatim: method.rawValue)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(
                backgroundProminence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Self.tint(for: method))
            )
            .lineLimit(1)
            .accessibilityLabel(Text("Method \(method.rawValue)"))
    }

    public static func tint(for method: HTTPMethod) -> Color {
        switch method {
        case .get: .textGreen
        case .post: .textOrange
        case .put: .textBlue
        case .patch: .textPurple
        case .delete: .textRed
        default: .textSecondary
        }
    }
}

/// Status code, reason and class with icon (F02.1).
public struct StatusBadge: View {
    let code: Int
    let reason: String

    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }

    public var body: some View {
        let statusClass = HTTPStatusClass(statusCode: code)
        let style = StatusBadgeStyle(statusClass: statusClass)
        Label {
            Text(verbatim: "\(code) \(reason)")
                .font(.headline.monospacedDigit())
        } icon: {
            Image(systemName: style.systemImage)
        }
        .foregroundStyle(style.tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status \(code), \(reason), \(statusClass.localizedName)"))
    }
}
