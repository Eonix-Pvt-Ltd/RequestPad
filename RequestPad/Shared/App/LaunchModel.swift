import Foundation
import OSLog
import Observation
import RPCore
import RPData
import RPServices
import RPStore

/// Prepares storage and the ``AppEnvironment`` before any feature UI appears, and exposes a recoverable failure.
@Observable
final class LaunchModel {
    enum State {
        case ready(AppModel)
        case failed(PresentedError)
    }

    private(set) var state: State

    init(makeEnvironment: @MainActor () throws(DataError) -> AppEnvironment = LaunchModel.makeLiveEnvironment) {
        state = Self.run(makeEnvironment)
    }

    /// Re-attempts launch after a failure ("Try Again").
    func retry(makeEnvironment: @MainActor () throws(DataError) -> AppEnvironment = LaunchModel.makeLiveEnvironment) {
        state = Self.run(makeEnvironment)
    }

    var appModel: AppModel? {
        if case .ready(let model) = state { return model }
        return nil
    }

    private static func run(_ makeEnvironment: @MainActor () throws(DataError) -> AppEnvironment) -> State {
        do {
            let environment = try makeEnvironment()
            Log.logger(.app).info("Launch preparation finished")
            let store = EntitlementManager(client: environment.storeClient, state: EntitlementState())
            return .ready(AppModel(environment: environment, store: store))
        } catch {
            Log.logger(.app).error("Launch preparation failed: \(error.localizedDescription, privacy: .public)")
            return .failed(PresentedError(error))
        }
    }

    nonisolated static func prepareLiveLocations() throws(StorageLocationError) -> StorageLocations {
        do {
            let locations = try StorageLocations.live()
            try locations.prepare()
            return locations
        } catch let error as StorageLocationError {
            throw error
        } catch {
            throw .applicationSupportUnavailable(underlying: error.localizedDescription)
        }
    }

    static func makeLiveEnvironment() throws(DataError) -> AppEnvironment {
        let locations: StorageLocations
        do {
            locations = try prepareLiveLocations()
        } catch {
            throw .storeUnavailable(underlying: error.errorDescription ?? "storage")
        }
        return try AppEnvironment.live(locations: locations)
    }
}
