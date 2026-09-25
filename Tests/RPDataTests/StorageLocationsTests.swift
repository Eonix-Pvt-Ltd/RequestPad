import Foundation
import Testing

@testable import RPData

@Suite("StorageLocations")
struct StorageLocationsTests {
    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "StorageLocationsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func derivedPaths() {
        let locations = StorageLocations(
            applicationSupport: URL(filePath: "/support", directoryHint: .isDirectory),
            temporary: URL(filePath: "/tmp-root", directoryHint: .isDirectory))
        #expect(locations.databaseFile.path() == "/support/RequestPad.store")
        #expect(locations.diagnosticsDirectory.path() == "/support/Diagnostics/")
        #expect(locations.responseBodiesDirectory.path() == "/tmp-root/Responses/")
        #expect(locations.ownedDirectories == [locations.diagnosticsDirectory, locations.responseBodiesDirectory])
    }

    @Test func prepareCreatesDirectoriesAndIsIdempotent() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StorageLocations(
            applicationSupport: root.appending(path: "support"), temporary: root.appending(path: "tmp"))
        try locations.prepare()
        try locations.prepare()
        for directory in locations.ownedDirectories {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory)
            )
            #expect(isDirectory.boolValue)
        }
    }

    @Test func prepareFailsWhenPathIsAFile() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appending(path: "support")
        try Data("x".utf8).write(to: blocker)
        let locations = StorageLocations(applicationSupport: blocker, temporary: root.appending(path: "tmp"))
        #expect {
            try locations.prepare()
        } throws: { error in
            guard case .cannotCreateDirectory(let name, _) = error as? StorageLocationError else { return false }
            return name == "Diagnostics"
        }
    }

    @Test func liveLocationsResolve() throws {
        let locations = try StorageLocations.live()
        #expect(locations.applicationSupport.isFileURL)
        #expect(locations.temporary.isFileURL)
    }

    @Test func errorsAreUserPresentable() {
        let errors: [StorageLocationError] = [
            .applicationSupportUnavailable(underlying: "x"),
            .cannotCreateDirectory(name: "Diagnostics", underlying: "y"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
        #expect(errors[1].errorDescription?.contains("Diagnostics") == true)
    }
}
