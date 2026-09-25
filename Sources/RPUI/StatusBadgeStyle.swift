import RPCore
import SwiftUI

/// Visual treatment of a response status. Pairs a symbol and a text label with the tint so that status is never
/// conveyed by color alone (F02.1, B8).
public struct StatusBadgeStyle: Equatable, Sendable {
    public let systemImage: String
    public let tint: Color

    public init(statusClass: HTTPStatusClass) {
        switch statusClass {
        case .informational:
            systemImage = "info.circle"
            tint = .textBlue
        case .success:
            systemImage = "checkmark.circle"
            tint = .textGreen
        case .redirection:
            systemImage = "arrow.triangle.turn.up.right.circle"
            tint = .textOrange
        case .clientError:
            systemImage = "exclamationmark.triangle"
            tint = .textRed
        case .serverError:
            systemImage = "xmark.octagon"
            tint = .textRed
        case .nonStandard:
            systemImage = "questionmark.circle"
            tint = .textSecondary
        }
    }
}

/// Spacing scale used by every view (no hard-coded spacing values).
public enum Spacing {
    public static let xxSmall: CGFloat = 2
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let xLarge: CGFloat = 24
}
