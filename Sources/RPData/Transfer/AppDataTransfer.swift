import Foundation
import RPCore

/// The "Export App Data" file (X04.1): native and sample collections, environments and globals. Secret values
/// are never exported — secret variables keep only their name (the value must be re-entered on import).
public struct AppDataExport: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    public static let maximumBytes = 50 * 1024 * 1024

    public struct ExportedCollection: Codable, Sendable, Hashable {
        public var id: UUID
        public var name: String
        public var storage: CollectionStorage
        public var settings: FolderSettings
        public var folders: [ExportedFolder]
        public var requests: [ExportedRequest]
        public var environments: [Environment]
    }

    public struct ExportedFolder: Codable, Sendable, Hashable {
        public var folder: RequestFolder
        public var parentID: UUID?
        public var sortOrder: Int
    }

    public struct ExportedRequest: Codable, Sendable, Hashable {
        public var request: RequestItem
        public var folderID: UUID?
    }

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var collections: [ExportedCollection]
    public var globals: [Environment]
}

/// Builds and applies ``AppDataExport`` files.
public struct AppDataTransfer: Sendable {
    public static let formatIdentifier = "lk.eonix.RequestPad.export"
    let store: LocalStore

    public init(store: LocalStore) {
        self.store = store
    }

    public func exportData(now: Date = Date()) async throws(DataError) -> Data {
        var collections: [AppDataExport.ExportedCollection] = []
        for summary in try await store.collections() where summary.storage != .folder {
            let collection = try await store.nativeCollection(summary.id)
            collections.append(
                AppDataExport.ExportedCollection(
                    id: summary.id, name: summary.name, storage: summary.storage, settings: collection.settings,
                    folders: collection.folders.map {
                        .init(folder: $0.folder, parentID: $0.parentID, sortOrder: $0.sortOrder)
                    },
                    requests: collection.requests.map { .init(request: $0.request, folderID: $0.folderID) },
                    environments: try await store.environments(for: summary.id)))
        }
        let export = AppDataExport(
            format: Self.formatIdentifier, version: AppDataExport.currentVersion, exportedAt: now,
            collections: collections,
            globals: try await store.environments(for: nil))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(export)
        } catch {
            throw .encodingFailed(what: "export")
        }
    }

    /// Validates and decodes an export without changing anything.
    public static func decode(_ data: Data) throws(DataError) -> AppDataExport {
        guard data.count <= AppDataExport.maximumBytes else {
            throw .importTooLarge(limitBytes: AppDataExport.maximumBytes)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Read the version first so newer files get a specific message.
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == formatIdentifier,
            let version = header.version
        else { throw .invalidExport(reason: "missing header") }
        guard version <= AppDataExport.currentVersion else { throw .unsupportedExportVersion(version) }
        do {
            return try decoder.decode(AppDataExport.self, from: data)
        } catch {
            throw .invalidExport(reason: "structure")
        }
    }

    /// Imports by merging on natural keys: items with the same id are replaced, others are added (X04.1).
    /// Returns the number of collections imported.
    @discardableResult
    public func importData(_ data: Data) async throws(DataError) -> Int {
        let export = try Self.decode(data)
        for collection in export.collections {
            try await store.createCollection(
                name: collection.name, storage: collection.storage, settings: collection.settings, id: collection.id)
            for folder in collection.folders {
                try await store.upsertFolder(
                    folder.folder, parentID: folder.parentID, in: collection.id, sortOrder: folder.sortOrder)
            }
            for request in collection.requests {
                try await store.upsertRequest(request.request, folderID: request.folderID, in: collection.id)
            }
            for (offset, environment) in collection.environments.enumerated() {
                try await store.upsertEnvironment(environment, for: collection.id, sortOrder: offset)
            }
        }
        for (offset, environment) in export.globals.enumerated() {
            try await store.upsertEnvironment(environment, for: nil, sortOrder: offset)
        }
        return export.collections.count
    }
}

/// "Erase All Data" (X04.2): database, Keychain secrets, preferences, diagnostics and cached response bodies.
/// Folder collections' files are the user's and are never deleted.
public struct DataEraser: Sendable {
    let store: LocalStore
    let secrets: any SecretStore
    let preferences: Preferences
    let locations: StorageLocations

    public init(store: LocalStore, secrets: any SecretStore, preferences: Preferences, locations: StorageLocations) {
        self.store = store
        self.secrets = secrets
        self.preferences = preferences
        self.locations = locations
    }

    public func eraseAll() async throws(DataError) {
        try await store.eraseEverything()
        try await secrets.deleteAll()
        preferences.removeAll()
        let fileManager = FileManager.default
        for directory in locations.ownedDirectories {
            let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for item in contents {
                do {
                    try fileManager.removeItem(at: item)
                } catch {
                    throw .fileWriteFailed(name: item.lastPathComponent, reason: error.localizedDescription)
                }
            }
        }
    }
}
