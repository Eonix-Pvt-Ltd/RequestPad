import Foundation

enum FixtureLoader {
    static func url(_ path: String) throws -> URL {
        guard let base = Bundle.module.resourceURL?.appending(path: "Fixtures") else {
            throw FixtureError.missing(path)
        }
        let url = base.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw FixtureError.missing(path)
        }
        return url
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    /// Relative paths of every file in a fixture directory with the given extension, sorted.
    static func files(in directory: String, withExtension fileExtension: String) throws -> [String] {
        let root = try url(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        return names.filter { $0.hasSuffix(".\(fileExtension)") }.sorted().map { "\(directory)/\($0)" }
    }

    enum FixtureError: Error {
        case missing(String)
    }
}
