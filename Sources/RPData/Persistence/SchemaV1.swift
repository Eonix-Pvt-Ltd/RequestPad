import Foundation
import SwiftData

/// Version 1 of the on-device store (B5, ADR-0005). Rules: every property has a default or is optional, no
/// `@Attribute(.unique)`, no relationships (records reference each other by `String` keys), nested values are
/// versioned JSON blobs of RPCore types. Each record has a natural key used for upserts.
public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            CollectionRecord.self, FolderRecord.self, RequestRecord.self, EnvironmentRecord.self, HistoryRecord.self,
            CookieRecord.self, SchemaCacheRecord.self, DraftRecord.self,
        ]
    }

    /// Natural key: `key` (UUID string). `kind` is ``RPCore/CollectionStorage`` raw value.
    @Model public final class CollectionRecord {
        public var key: String = ""
        public var name: String = ""
        public var kind: String = "native"
        /// Security-scoped bookmark of the folder for folder collections.
        public var bookmark: Data?
        /// `FolderSettings` JSON (headers, auth, variables, docs) for native collections.
        public var settingsJSON: Data?
        public var sortOrder: Int = 0
        public var useCookieJar: Bool = true
        public var createdAt: Date = Date.distantPast

        public init(key: String) { self.key = key }
    }

    /// Natural key: `key` (UUID string of the ``RPCore/RequestFolder`` id).
    @Model public final class FolderRecord {
        public var key: String = ""
        public var collectionKey: String = ""
        public var parentKey: String?
        public var name: String = ""
        public var sortOrder: Int = 0
        public var settingsJSON: Data?

        public init(key: String) { self.key = key }
    }

    /// Natural key: `key` (UUID string of the ``RPCore/RequestItem`` id).
    @Model public final class RequestRecord {
        public var key: String = ""
        public var collectionKey: String = ""
        public var folderKey: String?
        public var sortOrder: Int = 0
        /// Denormalized for search.
        public var name: String = ""
        public var method: String = "GET"
        public var url: String = ""
        public var itemJSON: Data?
        public var updatedAt: Date = Date.distantPast

        public init(key: String) { self.key = key }
    }

    /// Natural key: `key` (UUID string of the ``RPCore/Environment`` id). `collectionKey == nil` means globals.
    @Model public final class EnvironmentRecord {
        public var key: String = ""
        public var collectionKey: String?
        public var name: String = ""
        public var sortOrder: Int = 0
        /// `[Variable]` JSON. Secret variables carry only a Keychain reference.
        public var variablesJSON: Data?

        public init(key: String) { self.key = key }
    }

    /// Natural key: `key` (UUID string of the ``RPCore/HistoryEntry`` id).
    @Model public final class HistoryRecord {
        public var key: String = ""
        public var sentAt: Date = Date.distantPast
        public var name: String = ""
        public var method: String = "GET"
        public var url: String = ""
        public var statusCode: Int?
        public var entryJSON: Data?

        public init(key: String) { self.key = key }
    }

    /// Natural key: `key` = `domain|path|name` (RFC 6265 cookie identity).
    @Model public final class CookieRecord {
        public var key: String = ""
        public var domain: String = ""
        public var cookieJSON: Data?

        public init(key: String) { self.key = key }
    }

    /// Natural key: `key` = normalized endpoint URL.
    @Model public final class SchemaCacheRecord {
        public var key: String = ""
        public var fetchedAt: Date = Date.distantPast
        public var schemaJSON: Data?

        public init(key: String) { self.key = key }
    }

    /// Natural key: `key` = editor tab identifier.
    @Model public final class DraftRecord {
        public var key: String = ""
        public var requestKey: String?
        public var updatedAt: Date = Date.distantPast
        public var itemJSON: Data?

        public init(key: String) { self.key = key }
    }
}

/// Migration plan; V1 is the only version so far. New versions add a `MigrationStage` here.
public enum RequestPadMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public typealias CollectionRecord = SchemaV1.CollectionRecord
public typealias FolderRecord = SchemaV1.FolderRecord
public typealias RequestRecord = SchemaV1.RequestRecord
public typealias EnvironmentRecord = SchemaV1.EnvironmentRecord
public typealias HistoryRecord = SchemaV1.HistoryRecord
public typealias CookieRecord = SchemaV1.CookieRecord
public typealias SchemaCacheRecord = SchemaV1.SchemaCacheRecord
public typealias DraftRecord = SchemaV1.DraftRecord

public enum PersistenceContainer {
    /// The app's store: local only (`cloudKitDatabase: .none`), in Application Support.
    public static func make(at url: URL) throws(DataError) -> ModelContainer {
        let configuration = ModelConfiguration(
            "RequestPad", schema: Schema(versionedSchema: SchemaV1.self), url: url, cloudKitDatabase: .none)
        return try build(configuration)
    }

    /// An in-memory store for tests and previews.
    public static func makeInMemory() throws(DataError) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: SchemaV1.self), isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try build(configuration)
    }

    private static func build(_ configuration: ModelConfiguration) throws(DataError) -> ModelContainer {
        do {
            return try ModelContainer(
                for: Schema(versionedSchema: SchemaV1.self), migrationPlan: RequestPadMigrationPlan.self,
                configurations: [configuration])
        } catch {
            throw .storeUnavailable(underlying: String(describing: error))
        }
    }
}
