import Foundation

/// Errors from RPData with user-facing text (B3). Associated values never contain secrets or file contents.
public enum DataError: Error, Hashable, Sendable, LocalizedError {
    case storeUnavailable(underlying: String)
    case saveFailed(underlying: String)
    case encodingFailed(what: String)
    case notFound(what: String)
    case keychain(status: Int32, operation: String)
    case keychainItemNotFound
    case authenticationFailed(reason: String)
    case bookmarkStale
    case bookmarkUnresolvable(reason: String)
    case accessDenied(path: String)
    case fileReadFailed(name: String, reason: String)
    case fileWriteFailed(name: String, reason: String)
    case fileConflict(name: String)
    case invalidName(String)
    case nameInUse(String)
    case folderNotEmpty
    case notABrunoCollection
    case tooManyFiles(limit: Int)
    case importTooLarge(limitBytes: Int)
    case unsupportedExportVersion(Int)
    case invalidExport(reason: String)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable: String(localized: "RequestPad can't open its database.", bundle: .module)
        case .saveFailed: String(localized: "Your changes couldn't be saved.", bundle: .module)
        case .encodingFailed(let what): String(localized: "RequestPad couldn't store the \(what).", bundle: .module)
        case .notFound(let what): String(localized: "The \(what) no longer exists.", bundle: .module)
        case .keychain(let status, let operation):
            String(localized: "The Keychain couldn't \(operation) the secret (error \(status)).", bundle: .module)
        case .keychainItemNotFound: String(localized: "The secret isn't stored on this device.", bundle: .module)
        case .authenticationFailed:
            String(localized: "Authentication failed, so the secret stays hidden.", bundle: .module)
        case .bookmarkStale:
            String(localized: "RequestPad needs permission to open this folder again.", bundle: .module)
        case .bookmarkUnresolvable:
            String(localized: "The folder can't be found. It may have been moved or deleted.", bundle: .module)
        case .accessDenied(let path):
            String(localized: "RequestPad doesn't have permission to open “\(path)”.", bundle: .module)
        case .fileReadFailed(let name, _): String(localized: "“\(name)” couldn't be read.", bundle: .module)
        case .fileWriteFailed(let name, _): String(localized: "“\(name)” couldn't be saved.", bundle: .module)
        case .fileConflict(let name): String(localized: "“\(name)” was changed outside RequestPad.", bundle: .module)
        case .invalidName(let name): String(localized: "“\(name)” can't be used as a name.", bundle: .module)
        case .nameInUse(let name): String(localized: "“\(name)” already exists.", bundle: .module)
        case .folderNotEmpty: String(localized: "The folder isn't empty and isn't a Bruno collection.", bundle: .module)
        case .notABrunoCollection: String(localized: "The folder doesn't contain a bruno.json file.", bundle: .module)
        case .tooManyFiles(let limit):
            String(localized: "The collection has more than \(limit) files.", bundle: .module)
        case .importTooLarge(let limit):
            String(
                localized:
                    "The file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)).",
                bundle: .module)
        case .unsupportedExportVersion(let version):
            String(localized: "This export was made by a newer RequestPad (format \(version)).", bundle: .module)
        case .invalidExport: String(localized: "The file isn't a RequestPad export.", bundle: .module)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .bookmarkStale, .accessDenied:
            String(localized: "Choose Grant Access and select the folder again.", bundle: .module)
        case .bookmarkUnresolvable:
            String(
                localized: "Remove the collection from RequestPad, then open the folder from its new location.",
                bundle: .module)
        case .fileConflict:
            String(localized: "Choose whether to keep your version or use the file on disk.", bundle: .module)
        case .invalidName, .nameInUse: String(localized: "Choose a different name.", bundle: .module)
        case .unsupportedExportVersion:
            String(localized: "Update RequestPad, then import the file again.", bundle: .module)
        case .folderNotEmpty, .notABrunoCollection:
            String(localized: "Choose an empty folder or a folder containing bruno.json.", bundle: .module)
        default:
            String(localized: "Try again. If the problem continues, contact support from Settings.", bundle: .module)
        }
    }
}
