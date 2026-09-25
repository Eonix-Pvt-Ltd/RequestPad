import Foundation

/// A collection produced by an importer (OpenAPI, Postman), ready to be saved as a native or folder collection.
/// Importers build the whole value or throw, so nothing partial is ever saved (P02.3).
public struct ImportedCollection: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        /// Folder path (`/`-separated) or `nil` for the collection root.
        public var folderPath: String?
        public var request: RequestItem

        public init(folderPath: String?, request: RequestItem) {
            self.folderPath = folderPath
            self.request = request
        }
    }

    public var name: String
    public var settings: FolderSettings
    public var folders: [RequestFolder]
    public var items: [Item]
    public var environments: [Environment]
    /// Things that were skipped or approximated, shown after import.
    public var notices: [String]

    public init(
        name: String, settings: FolderSettings = FolderSettings(), folders: [RequestFolder] = [], items: [Item] = [],
        environments: [Environment] = [], notices: [String] = []
    ) {
        self.name = name
        self.settings = settings
        self.folders = folders
        self.items = items
        self.environments = environments
        self.notices = notices
    }

    /// Adds a folder for `path` (and its parents) if missing.
    mutating func ensureFolder(_ path: String) {
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            if !folders.contains(where: { $0.path == current }) {
                folders.append(RequestFolder(name: String(component), path: current))
            }
        }
    }

    mutating func notice(_ text: String) {
        if !notices.contains(text) { notices.append(text) }
    }
}

/// Loads JSON or YAML text into a ``JSONValue``, choosing the parser from the first significant character.
enum StructuredDocument {
    static let maximumBytes = 10 * 1024 * 1024

    static func parse(_ data: Data) throws(CoreError) -> JSONValue {
        guard data.count <= maximumBytes else { throw .inputTooLarge(limitBytes: maximumBytes) }
        let firstSignificant = data.first(where: { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) })
        if firstSignificant == UInt8(ascii: "{") || firstSignificant == UInt8(ascii: "[") {
            return try JSONParser(maximumBytes: maximumBytes, maximumDepth: 128).parse(data)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw .unsupportedDocument(reason: "The file isn't UTF-8 text.")
        }
        return try YAMLParser(maximumBytes: maximumBytes, maximumDepth: 128).parse(text)
    }
}
