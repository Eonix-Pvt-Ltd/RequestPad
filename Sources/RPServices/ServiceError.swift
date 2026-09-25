import Foundation
import RPCore

/// Errors from RPServices with specific, user-facing text (F01.7, B3). Associated values never contain secrets,
/// request bodies or header values.
public enum ServiceError: Error, Hashable, Sendable, LocalizedError {
    case invalidMethod(String)
    case unsupportedScheme(String)
    case notConnected
    case timedOut(seconds: Int)
    case cannotFindHost(String)
    case cannotConnect(String)
    case connectionLost
    case appTransportSecurity(host: String)
    case localNetworkDenied(host: String)
    case tlsFailure(host: String)
    case tooManyRedirects(Int)
    case responseTooLarge(limitBytes: Int)
    case fileUnavailable(name: String)
    case cancelled
    case network(code: Int, message: String)
    case echoUnavailable(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMethod(let method):
            String(localized: "“\(method)” can't be sent as an HTTP method.", bundle: .module)
        case .unsupportedScheme(let scheme):
            String(localized: "RequestPad can only send http and https requests, not “\(scheme)”.", bundle: .module)
        case .notConnected: String(localized: "You're offline.", bundle: .module)
        case .timedOut(let seconds):
            String(localized: "The server didn't respond within \(seconds) seconds.", bundle: .module)
        case .cannotFindHost(let host): String(localized: "The server “\(host)” couldn't be found.", bundle: .module)
        case .cannotConnect(let host): String(localized: "RequestPad couldn't connect to “\(host)”.", bundle: .module)
        case .connectionLost: String(localized: "The connection was lost.", bundle: .module)
        case .appTransportSecurity(let host):
            String(
                localized:
                    "Plain http:// connections to “\(host)” aren't allowed. Apple requires https:// for internet hosts.",
                bundle: .module)
        case .localNetworkDenied(let host):
            String(
                localized: "RequestPad doesn't have permission to reach “\(host)” on your local network.",
                bundle: .module)
        case .tlsFailure(let host):
            String(localized: "A secure connection to “\(host)” couldn't be established.", bundle: .module)
        case .tooManyRedirects(let count):
            String(localized: "The server redirected more than \(count) times.", bundle: .module)
        case .responseTooLarge(let limit):
            String(
                localized:
                    "The response is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)).",
                bundle: .module)
        case .fileUnavailable(let name): String(localized: "The file “\(name)” can't be opened.", bundle: .module)
        case .cancelled: String(localized: "The request was cancelled.", bundle: .module)
        case .network(let code, let message):
            String(localized: "The request failed (\(code)): \(message)", bundle: .module)
        case .echoUnavailable: String(localized: "Local Echo couldn't start.", bundle: .module)
        case .notFound(let what): String(localized: "The \(what) couldn't be found.", bundle: .module)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidMethod:
            String(localized: "Use a method made of letters, digits and !#$%&'*+-.^_`|~.", bundle: .module)
        case .unsupportedScheme, .appTransportSecurity:
            String(localized: "Change the URL to start with https://.", bundle: .module)
        case .notConnected: String(localized: "Check your internet connection, then send again.", bundle: .module)
        case .timedOut:
            String(localized: "Try again, or increase the timeout in the request's Settings tab.", bundle: .module)
        case .cannotFindHost: String(localized: "Check the host name and your environment variables.", bundle: .module)
        case .cannotConnect:
            String(localized: "Make sure the server is running and the port is correct.", bundle: .module)
        case .localNetworkDenied:
            String(
                localized: "Allow Local Network access for RequestPad in System Settings → Privacy & Security.",
                bundle: .module)
        case .tlsFailure:
            String(
                localized:
                    "The server's certificate isn't trusted by this device. RequestPad doesn't bypass certificate checks.",
                bundle: .module)
        case .tooManyRedirects:
            String(localized: "Turn off Follow Redirects to inspect the first redirect.", bundle: .module)
        case .fileUnavailable: String(localized: "Choose the file again in the Body tab.", bundle: .module)
        case .responseTooLarge: String(localized: "Request a smaller range of data.", bundle: .module)
        default:
            String(
                localized: "Try again. If the problem continues, export diagnostics from Settings and contact support.",
                bundle: .module)
        }
    }

    /// Maps a URLSession error to a specific case (F01.7).
    public static func from(_ error: Error, host: String, timeoutSeconds: Int) -> ServiceError {
        if let service = error as? ServiceError { return service }
        guard let urlError = error as? URLError else {
            let nsError = error as NSError
            return .network(code: nsError.code, message: nsError.localizedDescription)
        }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut(seconds: timeoutSeconds)
        case .cannotFindHost, .dnsLookupFailed: return .cannotFindHost(host)
        case .cannotConnectToHost: return .cannotConnect(host)
        case .networkConnectionLost: return .connectionLost
        case .appTransportSecurityRequiresSecureConnection: return .appTransportSecurity(host: host)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid,
            .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return .tlsFailure(host: host)
        case .httpTooManyRedirects: return .tooManyRedirects(RPCore.RequestDefaults.maximumRedirects)
        case .notConnectedToInternet:
            // Local Network privacy denial surfaces as "not connected" for LAN hosts.
            return RPCore.LocalAddress.isLocal(host: host) && !RPCore.LocalAddress.isLoopback(host: host)
                ? .localNetworkDenied(host: host) : .notConnected
        case .fileDoesNotExist, .noPermissionsToReadFile:
            return .fileUnavailable(name: urlError.failingURL?.lastPathComponent ?? "file")
        default: return .network(code: urlError.errorCode, message: urlError.localizedDescription)
        }
    }
}
