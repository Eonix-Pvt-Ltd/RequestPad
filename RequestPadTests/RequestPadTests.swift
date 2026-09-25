import Foundation
import RPData
import Testing

@testable import RequestPad

@MainActor
@Suite("LaunchModel")
struct LaunchModelTests {
    private let locations = StorageLocations(
        applicationSupport: URL(filePath: "/support", directoryHint: .isDirectory),
        temporary: URL(filePath: "/tmp-root", directoryHint: .isDirectory))

    @Test func successfulPreparationIsReady() {
        let model = LaunchModel { locations }
        #expect(model.state == .ready(locations))
    }

    @Test func failedPreparationIsRecoverableByRetry() {
        let failure = StorageLocationError.cannotCreateDirectory(name: "Diagnostics", underlying: "disk full")
        let model = LaunchModel { () throws(StorageLocationError) -> StorageLocations in throw failure }
        #expect(model.state == .failed(failure))

        model.retry { locations }
        #expect(model.state == .ready(locations))
    }

    @Test func livePreparationSucceedsInTestHost() throws {
        let prepared = try LaunchModel.prepareLiveLocations()
        for directory in prepared.ownedDirectories {
            #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        }
    }
}
