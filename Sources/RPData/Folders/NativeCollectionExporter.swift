import Foundation
import RPCore

/// "Convert to Folder Collection…" (P01.7): writes a native collection into an empty folder as a Bruno collection.
/// Secret variable values stay in the Keychain; only their names are written (`vars:secret`).
public enum NativeCollectionExporter {
    /// Returns the number of request files written.
    @discardableResult
    public static func export(
        _ collection: NativeCollection, environments: [Environment], to folder: URL, collectionKey: String
    ) async throws(DataError) -> Int {
        try FolderCollectionRepository.createCollection(named: collection.summary.name, in: folder)
        let repository = FolderCollectionRepository(root: folder, collectionKey: collectionKey)
        _ = try await repository.load()
        try await repository.saveCollectionSettings(collection.settings)

        // Create folders parent-first so paths exist before their children.
        var pathByID: [UUID: String] = [:]
        var remaining = collection.folders.sorted { $0.sortOrder < $1.sortOrder }
        while !remaining.isEmpty {
            let before = remaining.count
            for stored in remaining where stored.parentID == nil || pathByID[stored.parentID ?? UUID()] != nil {
                let parentPath = stored.parentID.flatMap { pathByID[$0] }
                let path = try await repository.createFolder(named: stored.folder.name, in: parentPath)
                var settings = stored.folder.settings
                settings.sequence = stored.sortOrder
                try await repository.saveFolderSettings(settings, name: stored.folder.name, at: path, overwrite: true)
                pathByID[stored.id] = path
            }
            remaining.removeAll { pathByID[$0.id] != nil }
            // Folders whose parent is missing (corrupt data) go to the root rather than looping forever.
            if remaining.count == before {
                remaining = remaining.map { StoredFolder(folder: $0.folder, parentID: nil, sortOrder: $0.sortOrder) }
            }
        }
        for stored in collection.requests {
            try await repository.saveRequest(
                stored.request, at: nil, inFolder: stored.folderID.flatMap { pathByID[$0] })
        }
        for environment in environments {
            try await repository.saveEnvironment(environment, fileName: nil)
        }
        return collection.requests.count
    }
}
