import Foundation

/// Directories the app owns inside its sandbox container. Every path is derived from injected base directories so
/// tests can run against a temporary folder, and so "Erase All Data" (X04.2) can enumerate exactly what to remove.
public struct StorageLocations: Sendable, Equatable {
    public let applicationSupport: URL
    public let temporary: URL

    public init(applicationSupport: URL, temporary: URL) {
        self.applicationSupport = applicationSupport
        self.temporary = temporary
    }

    /// Locations inside the current process's sandbox container.
    public static func live(fileManager: FileManager = .default) throws -> StorageLocations {
        let support: URL
        do {
            support = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            throw StorageLocationError.applicationSupportUnavailable(underlying: error.localizedDescription)
        }
        return StorageLocations(applicationSupport: support, temporary: fileManager.temporaryDirectory)
    }

    /// SwiftData store file.
    public var databaseFile: URL {
        applicationSupport.appending(path: "RequestPad.store", directoryHint: .notDirectory)
    }
    /// Persisted MetricKit payloads (B1).
    public var diagnosticsDirectory: URL {
        applicationSupport.appending(path: "Diagnostics", directoryHint: .isDirectory)
    }
    /// Response bodies larger than the render cap, streamed to disk (F02.7). Purged on launch.
    public var responseBodiesDirectory: URL { temporary.appending(path: "Responses", directoryHint: .isDirectory) }

    /// Every directory the app creates; used by "Erase All Data".
    public var ownedDirectories: [URL] { [diagnosticsDirectory, responseBodiesDirectory] }

    /// Creates the owned directories if they are missing.
    public func prepare(fileManager: FileManager = .default) throws {
        for directory in ownedDirectories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw StorageLocationError.cannotCreateDirectory(
                    name: directory.lastPathComponent, underlying: error.localizedDescription)
            }
        }
    }
}

public enum StorageLocationError: Error, Equatable, LocalizedError {
    case applicationSupportUnavailable(underlying: String)
    case cannotCreateDirectory(name: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            String(localized: "RequestPad can't open its data folder.", bundle: .module)
        case .cannotCreateDirectory(let name, _):
            String(localized: "RequestPad can't create the “\(name)” folder.", bundle: .module)
        }
    }

    public var recoverySuggestion: String? {
        String(
            localized:
                "Make sure your device has free storage space, then restart RequestPad. If this keeps happening, contact support.",
            bundle: .module)
    }
}
