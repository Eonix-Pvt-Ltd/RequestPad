import Foundation

/// The class of an HTTP status code (RFC 9110 §15). Drives the status badge's icon, label and color so that color
/// is never the only signal (F02.1).
public enum HTTPStatusClass: String, Sendable, CaseIterable {
    case informational
    case success
    case redirection
    case clientError
    case serverError
    case nonStandard

    public init(statusCode: Int) {
        switch statusCode {
        case 100..<200: self = .informational
        case 200..<300: self = .success
        case 300..<400: self = .redirection
        case 400..<500: self = .clientError
        case 500..<600: self = .serverError
        default: self = .nonStandard
        }
    }

    /// Short, localized, human-readable class name shown next to the numeric code.
    public var localizedName: String {
        switch self {
        case .informational: String(localized: "Informational", bundle: .module)
        case .success: String(localized: "Success", bundle: .module)
        case .redirection: String(localized: "Redirect", bundle: .module)
        case .clientError: String(localized: "Client Error", bundle: .module)
        case .serverError: String(localized: "Server Error", bundle: .module)
        case .nonStandard: String(localized: "Non-standard", bundle: .module)
        }
    }
}
