import AppIntents
import Foundation
import RPCore
import RPData
import RPServices

/// A saved request, for Shortcuts (P08.1). The identifier is `collectionID|key`.
struct RequestEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Request"
    static let defaultQuery = RequestEntityQuery()

    let id: String
    let name: String
    let method: String
    let collectionName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(method) \(name)", subtitle: "\(collectionName)")
    }

    var reference: RequestReference? {
        EntityIdentifier.split(id).map { RequestReference(collectionID: $0.collectionID, key: $0.key) }
    }

    init(id: String, name: String, method: String, collectionName: String) {
        self.id = id
        self.name = name
        self.method = method
        self.collectionName = collectionName
    }

    init(_ summary: SavedRequestSummary) {
        self.init(
            id: EntityIdentifier.join(summary.reference.collectionID, summary.reference.key), name: summary.displayPath,
            method: summary.request.method.rawValue, collectionName: summary.collectionName)
    }
}

struct RequestEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [RequestEntity] {
        let all = try await Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [RequestEntity] {
        try await Self.all()
    }

    @MainActor
    func entities(matching string: String) async throws -> [RequestEntity] {
        try await Self.all().filter {
            $0.name.localizedCaseInsensitiveContains(string)
                || $0.collectionName.localizedCaseInsensitiveContains(string)
        }
    }

    @MainActor
    static func all() async throws -> [RequestEntity] {
        try await AppRuntime.shared.loadedModel().savedRequests().map(RequestEntity.init)
    }
}

/// A collection environment, for Shortcuts. The identifier is `collectionID|key`.
struct EnvironmentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Environment"
    static let defaultQuery = EnvironmentEntityQuery()

    let id: String
    let name: String
    let collectionName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(collectionName)")
    }

    var target: (collectionID: UUID, key: String)? { EntityIdentifier.split(id) }
}

struct EnvironmentEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [EnvironmentEntity] {
        let all = try await Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [EnvironmentEntity] {
        try await Self.all()
    }

    @MainActor
    static func all() async throws -> [EnvironmentEntity] {
        let model = try await AppRuntime.shared.loadedModel()
        return model.collections.flatMap { state -> [EnvironmentEntity] in
            model.environments(for: state.id).map { entry in
                EnvironmentEntity(
                    id: EntityIdentifier.join(state.id, entry.key), name: entry.environment.name,
                    collectionName: state.summary.name)
            }
        }
    }
}

/// `collectionID|key` identifiers (keys may contain "/" for folder collections, never "|" first).
nonisolated enum EntityIdentifier {
    static func join(_ collectionID: UUID, _ key: String) -> String {
        "\(collectionID.uuidString)|\(key)"
    }

    static func split(_ id: String) -> (collectionID: UUID, key: String)? {
        guard let separator = id.firstIndex(of: "|"), let collectionID = UUID(uuidString: String(id[..<separator]))
        else {
            return nil
        }
        let key = String(id[id.index(after: separator)...])
        return key.isEmpty ? nil : (collectionID, key)
    }
}
