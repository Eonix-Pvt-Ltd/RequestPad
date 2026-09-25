import Foundation
import OSLog
import Observation
import RPData
import RPServices

/// Prepares on-disk locations before any feature UI appears and exposes the outcome to ``RootView``.
@Observable
final class LaunchModel {
    enum State: Equatable {
        case ready(StorageLocations)
        case failed(StorageLocationError)
    }

    private(set) var state: State

    init(prepare: () throws(StorageLocationError) -> StorageLocations = LaunchModel.prepareLiveLocations) {
        state = Self.run(prepare)
    }

    /// Re-attempts preparation after a failure (the "Try Again" action).
    func retry(prepare: () throws(StorageLocationError) -> StorageLocations = LaunchModel.prepareLiveLocations) {
        state = Self.run(prepare)
    }

    private static func run(_ prepare: () throws(StorageLocationError) -> StorageLocations) -> State {
        do {
            let locations = try prepare()
            Log.logger(.app).info("Launch preparation finished")
            return .ready(locations)
        } catch {
            Log.logger(.app).error("Launch preparation failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error)
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
}
