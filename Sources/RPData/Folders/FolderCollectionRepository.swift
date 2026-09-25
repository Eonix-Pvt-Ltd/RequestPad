import CryptoKit
import Foundation
import RPCore

/// A Bruno collection folder as RequestPad sees it (P01.2).
public struct FolderCollectionSnapshot: Sendable, Hashable {
    public struct Folder: Sendable, Hashable {
        /// `/`-separated path relative to the collection root.
        public var path: String
        public var name: String
        public var settings: FolderSettings
        public var hasUnsupportedScripts: Bool
    }

    public struct Request: Sendable, Hashable {
        /// File path relative to the root (`users/List users.bru`).
        public var path: String
        /// Containing folder path, `nil` at the root.
        public var folderPath: String?
        public var request: RequestItem
    }

    public struct EnvironmentFile: Sendable, Hashable {
        /// File name inside `environments/` (`Staging.bru`).
        public var fileName: String
        public var environment: Environment
    }

    /// A file that couldn't be read; the rest of the collection still loads.
    public struct Issue: Sendable, Hashable {
        public var path: String
        public var message: String
    }

    public var name: String
    public var settings: FolderSettings
    public var hasUnsupportedScripts: Bool
    public var folders: [Folder]
    public var requests: [Request]
    public var environments: [EnvironmentFile]
    public var issues: [Issue]
}

/// Reads and writes a Bruno collection folder (P01). The caller holds security-scoped access to `root`.
///
/// - Unknown blocks and formatting are preserved: each file's parsed ``RPCore/BruDocument`` is kept and re-encoded
///   with minimal changes.
/// - Writes are atomic and coordinated (`NSFileCoordinator`) so File Provider/iCloud Drive see consistent files.
/// - A save fails with ``DataError/fileConflict(name:)`` when the file changed on disk after it was loaded, unless
///   `overwrite` is set (the user chose "Keep Mine", P01.4).
public actor FolderCollectionRepository {
    public static let maximumFiles = 5_000
    public static let maximumDepth = 16
    static let environmentsDirectory = "environments"

    public nonisolated let root: URL
    /// `environmentKey` prefix for Keychain references of secret variables (stable per collection).
    public nonisolated let collectionKey: String
    private let fileManager = FileManager.default
    private var documents: [String: BruDocument] = [:]
    private var hashes: [String: String] = [:]
    private var manifest: BrunoManifest?

    public init(root: URL, collectionKey: String) {
        self.root = root.standardizedFileURL
        self.collectionKey = collectionKey
    }

    // MARK: Creating collections

    /// Creates `bruno.json` and `collection.bru` in an empty folder (P01.6).
    public static func createCollection(named name: String, in folder: URL) throws(DataError) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        if contents.contains(BrunoManifest.fileName) { throw .nameInUse(BrunoManifest.fileName) }
        guard contents.allSatisfy({ $0.hasPrefix(".") }) else { throw .folderNotEmpty }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidName(name) }
        try write(
            BrunoManifest(name: trimmed).encoded(), to: folder.appending(path: BrunoManifest.fileName),
            displayName: BrunoManifest.fileName)
        let collectionFile = try encodeFolder(FolderSettings(), name: nil, original: nil)
        try write(
            Data(collectionFile.utf8), to: folder.appending(path: "collection.bru"), displayName: "collection.bru")
    }

    // MARK: Loading

    public func load() throws(DataError) -> FolderCollectionSnapshot {
        let manifestURL = root.appending(path: BrunoManifest.fileName)
        guard fileManager.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            throw .notABrunoCollection
        }
        let manifestData = try read(manifestURL, displayName: BrunoManifest.fileName)
        let manifest: BrunoManifest
        do {
            manifest = try BrunoManifest.decode(manifestData)
        } catch {
            throw .fileReadFailed(name: BrunoManifest.fileName, reason: error.errorDescription ?? "invalid")
        }
        self.manifest = manifest
        documents.removeAll()
        hashes.removeAll()

        var issues: [FolderCollectionSnapshot.Issue] = []
        var collectionSettings = FolderSettings()
        var collectionScripts = false
        if let (document, _) = try loadDocument("collection.bru", issues: &issues) {
            do {
                let decoded = try BruFolderCodec.decode(document)
                collectionSettings = decoded.settings
                collectionScripts = decoded.hasUnsupportedScripts
            } catch {
                issues.append(.init(path: "collection.bru", message: error.errorDescription ?? "invalid"))
            }
        }

        let ignored = Set(manifest.ignore + ["node_modules", ".git"])
        var folders: [FolderCollectionSnapshot.Folder] = []
        var requests: [FolderCollectionSnapshot.Request] = []
        var fileCount = 0
        var pending: [(path: String, depth: Int)] = [("", 0)]
        while let (directory, depth) = pending.popLast() {
            let directoryURL = directory.isEmpty ? root : root.appending(path: directory, directoryHint: .isDirectory)
            let entries: [String]
            do {
                entries = try fileManager.contentsOfDirectory(atPath: directoryURL.path(percentEncoded: false)).sorted()
            } catch {
                issues.append(.init(path: directory.isEmpty ? "/" : directory, message: "The folder can't be read."))
                continue
            }
            for entry in entries where !entry.hasPrefix(".") && !ignored.contains(entry) {
                let path = directory.isEmpty ? entry : "\(directory)/\(entry)"
                let url = root.appending(path: path)
                // Symbolic links are skipped: they could point outside the granted folder or form cycles.
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard let values, values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if directory.isEmpty && entry == Self.environmentsDirectory { continue }
                    guard depth + 1 <= Self.maximumDepth else {
                        issues.append(
                            .init(
                                path: path,
                                message: "Folders nested more than \(Self.maximumDepth) levels deep are skipped."))
                        continue
                    }
                    folders.append(try loadFolder(path, issues: &issues))
                    pending.append((path, depth + 1))
                    continue
                }
                guard entry.hasSuffix(".bru"), entry != "collection.bru", entry != "folder.bru" else { continue }
                fileCount += 1
                guard fileCount <= Self.maximumFiles else { throw .tooManyFiles(limit: Self.maximumFiles) }
                guard let (document, _) = try loadDocument(path, issues: &issues) else { continue }
                do {
                    var request = try BruRequestCodec.decode(document)
                    if request.name.isEmpty { request.name = String(entry.dropLast(4)) }
                    requests.append(
                        .init(path: path, folderPath: directory.isEmpty ? nil : directory, request: request))
                } catch {
                    issues.append(.init(path: path, message: error.errorDescription ?? "invalid"))
                }
            }
        }

        var environments: [FolderCollectionSnapshot.EnvironmentFile] = []
        let environmentsURL = root.appending(path: Self.environmentsDirectory, directoryHint: .isDirectory)
        let environmentFiles =
            (try? fileManager.contentsOfDirectory(atPath: environmentsURL.path(percentEncoded: false))) ?? []
        for fileName in environmentFiles.sorted() where fileName.hasSuffix(".bru") && !fileName.hasPrefix(".") {
            let path = "\(Self.environmentsDirectory)/\(fileName)"
            guard let (_, text) = try loadDocument(path, issues: &issues) else { continue }
            do {
                let (environment, _) = try BruEnvironmentCodec.decode(
                    text, name: String(fileName.dropLast(4)), environmentKey: environmentKey(for: fileName))
                environments.append(.init(fileName: fileName, environment: environment))
            } catch {
                issues.append(.init(path: path, message: error.errorDescription ?? "invalid"))
            }
        }

        folders.sort { ($0.settings.sequence ?? Int.max, $0.path) < ($1.settings.sequence ?? Int.max, $1.path) }
        requests.sort {
            ($0.folderPath ?? "", $0.request.sortOrder, $0.request.name) < (
                $1.folderPath ?? "", $1.request.sortOrder, $1.request.name
            )
        }
        return FolderCollectionSnapshot(
            name: manifest.name, settings: collectionSettings, hasUnsupportedScripts: collectionScripts,
            folders: folders,
            requests: requests, environments: environments, issues: issues)
    }

    /// Keychain `environmentKey` for an environment file.
    public nonisolated func environmentKey(for fileName: String) -> String {
        "\(collectionKey)/\(Self.environmentsDirectory)/\(fileName)"
    }

    /// Whether any `.bru`/`bruno.json` file changed on disk since the last load or save (P01.4).
    public func hasExternalChanges() -> Bool {
        let current = currentHashes()
        return current != hashes
    }

    /// Paths whose content differs on disk from what was loaded/saved.
    public func changedPaths() -> [String] {
        let current = currentHashes()
        return Set(current.keys).union(hashes.keys).filter { current[$0] != hashes[$0] }.sorted()
    }

    // MARK: Requests

    /// Saves a request. `path` is its existing file (nil for a new request, which gets a file named after it).
    /// Returns the file path used.
    @discardableResult
    public func saveRequest(
        _ request: RequestItem, at path: String?, inFolder folderPath: String?, overwrite: Bool = false
    ) throws(DataError) -> String {
        let targetPath: String
        if let path {
            targetPath = path
            try checkConflict(path, overwrite: overwrite)
        } else {
            targetPath = try uniqueFilePath(for: request.name, in: folderPath)
        }
        let text: String
        do {
            text = try BruRequestCodec.encode(request, preserving: documents[targetPath])
        } catch {
            throw .fileWriteFailed(name: displayName(targetPath), reason: error.errorDescription ?? "encode")
        }
        try store(text, at: targetPath)
        return targetPath
    }

    /// Renames a request (meta name and file name). Returns the new path.
    public func renameRequest(_ request: RequestItem, at path: String, to newName: String) throws(DataError) -> String {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidName(newName) }
        try checkConflict(path, overwrite: false)
        var renamed = request
        renamed.name = trimmed
        let folderPath = path.contains("/") ? String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)]) : nil
        let newPath = try uniqueFilePath(for: trimmed, in: folderPath, excluding: path)
        try move(path, to: newPath)
        return try saveRequest(renamed, at: newPath, inFolder: folderPath, overwrite: true)
    }

    /// Moves a request file into another folder (or the root).
    public func moveRequest(at path: String, toFolder folderPath: String?) throws(DataError) -> String {
        let fileName = String(path.split(separator: "/").last ?? Substring(path))
        let base = String(fileName.dropLast(4))
        let newPath = try uniqueFilePath(for: base, in: folderPath, excluding: path)
        try move(path, to: newPath)
        return newPath
    }

    public func deleteRequest(at path: String) throws(DataError) {
        try removeItem(path)
    }

    // MARK: Folders

    public func createFolder(named name: String, in parentPath: String?) throws(DataError) -> String {
        let component = try Self.sanitizedComponent(name)
        let path = parentPath.map { "\($0)/\(component)" } ?? component
        let url = root.appending(path: path, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { throw .nameInUse(component) }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw .fileWriteFailed(name: component, reason: error.localizedDescription)
        }
        try saveFolderSettings(FolderSettings(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), at: path)
        return path
    }

    public func saveFolderSettings(
        _ settings: FolderSettings, name: String?, at folderPath: String, overwrite: Bool = false
    ) throws(DataError) {
        let path = "\(folderPath)/folder.bru"
        try checkConflict(path, overwrite: overwrite)
        try store(try Self.encodeFolder(settings, name: name, original: documents[path]), at: path)
    }

    public func saveCollectionSettings(_ settings: FolderSettings, overwrite: Bool = false) throws(DataError) {
        let path = "collection.bru"
        try checkConflict(path, overwrite: overwrite)
        try store(try Self.encodeFolder(settings, name: nil, original: documents[path]), at: path)
    }

    /// Renames a folder directory and its `folder.bru` meta name. Returns the new path.
    public func renameFolder(at path: String, to newName: String) throws(DataError) -> String {
        let component = try Self.sanitizedComponent(newName)
        let parent = path.contains("/") ? String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)]) : nil
        let newPath = parent.map { "\($0)/\(component)" } ?? component
        guard newPath != path else { return path }
        guard !fileManager.fileExists(atPath: root.appending(path: newPath).path(percentEncoded: false)) else {
            throw .nameInUse(component)
        }
        try move(path, to: newPath)
        let settingsPath = "\(newPath)/folder.bru"
        let settings = (try? documents[settingsPath].map(BruFolderCodec.decode)?.settings) ?? FolderSettings()
        try saveFolderSettings(
            settings, name: newName.trimmingCharacters(in: .whitespacesAndNewlines), at: newPath, overwrite: true)
        return newPath
    }

    /// Deletes a folder and everything in it (explicit user action only).
    public func deleteFolder(at path: String) throws(DataError) {
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { throw .invalidName(path) }
        try removeItem(path)
    }

    // MARK: Environments

    /// Saves an environment to `environments/<name>.bru`. Secret values are not written (P01.5).
    @discardableResult
    public func saveEnvironment(_ environment: Environment, fileName: String?, overwrite: Bool = false)
        throws(DataError) -> String
    {
        let name: String
        if let fileName {
            name = fileName
        } else {
            name = "\(try Self.sanitizedComponent(environment.name)).bru"
        }
        let path = "\(Self.environmentsDirectory)/\(name)"
        if fileName == nil, fileManager.fileExists(atPath: root.appending(path: path).path(percentEncoded: false)) {
            throw .nameInUse(environment.name)
        }
        try checkConflict(path, overwrite: overwrite)
        let directory = root.appending(path: Self.environmentsDirectory, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw .fileWriteFailed(name: Self.environmentsDirectory, reason: error.localizedDescription)
            }
        }
        let text: String
        do {
            text = try BruEnvironmentCodec.encode(environment, preserving: documents[path])
        } catch {
            throw .fileWriteFailed(name: name, reason: error.errorDescription ?? "encode")
        }
        try store(text, at: path)
        return name
    }

    public func deleteEnvironment(fileName: String) throws(DataError) {
        try removeItem("\(Self.environmentsDirectory)/\(fileName)")
    }

    // MARK: Names

    /// A file-system-safe name component (P01): no path separators or reserved characters, 1–100 characters.
    public static func sanitizedComponent(_ name: String) throws(DataError) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(100)).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != "folder", cleaned != "collection" else { throw .invalidName(name) }
        return cleaned
    }

    private func uniqueFilePath(for name: String, in folderPath: String?, excluding: String? = nil) throws(DataError)
        -> String
    {
        let base = try Self.sanitizedComponent(name)
        for attempt in 1...1_000 {
            let fileName = attempt == 1 ? "\(base).bru" : "\(base) \(attempt).bru"
            let path = folderPath.map { "\($0)/\(fileName)" } ?? fileName
            if path == excluding
                || !fileManager.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
            {
                return path
            }
        }
        throw .nameInUse(name)
    }

    // MARK: File I/O

    private func loadFolder(_ path: String, issues: inout [FolderCollectionSnapshot.Issue]) throws(DataError)
        -> FolderCollectionSnapshot.Folder
    {
        let name = String(path.split(separator: "/").last ?? Substring(path))
        guard let (document, _) = try loadDocument("\(path)/folder.bru", issues: &issues, required: false) else {
            return .init(path: path, name: name, settings: FolderSettings(), hasUnsupportedScripts: false)
        }
        do {
            let decoded = try BruFolderCodec.decode(document)
            return .init(
                path: path, name: decoded.name ?? name, settings: decoded.settings,
                hasUnsupportedScripts: decoded.hasUnsupportedScripts)
        } catch {
            issues.append(.init(path: "\(path)/folder.bru", message: error.errorDescription ?? "invalid"))
            return .init(path: path, name: name, settings: FolderSettings(), hasUnsupportedScripts: false)
        }
    }

    /// Reads and parses a `.bru` file, remembering its document and hash. Returns nil (with an issue) on errors.
    private func loadDocument(
        _ path: String, issues: inout [FolderCollectionSnapshot.Issue], required: Bool = false
    ) throws(DataError) -> (BruDocument, String)? {
        let url = root.appending(path: path)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data: Data
        do {
            data = try read(url, displayName: displayName(path))
        } catch {
            issues.append(.init(path: path, message: error.errorDescription ?? "unreadable"))
            return nil
        }
        hashes[path] = Self.hash(data)
        guard let text = String(data: data, encoding: .utf8) else {
            issues.append(.init(path: path, message: "The file isn't UTF-8 text."))
            return nil
        }
        do {
            let document = try BruDocument.parse(text)
            documents[path] = document
            return (document, text)
        } catch {
            issues.append(.init(path: path, message: error.errorDescription ?? "invalid"))
            return nil
        }
    }

    private func checkConflict(_ path: String, overwrite: Bool) throws(DataError) {
        guard !overwrite else { return }
        let url = root.appending(path: path)
        let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false))
        let known = hashes[path]
        switch (exists, known) {
        case (false, nil):
            return
        case (true, nil), (false, .some):
            throw .fileConflict(name: displayName(path))
        case (true, .some(let expected)):
            let current = (try? read(url, displayName: displayName(path))).map(Self.hash)
            if current != expected { throw .fileConflict(name: displayName(path)) }
        }
    }

    private func store(_ text: String, at path: String) throws(DataError) {
        let data = Data(text.utf8)
        try Self.write(data, to: root.appending(path: path), displayName: displayName(path))
        hashes[path] = Self.hash(data)
        documents[path] = try? BruDocument.parse(text)
    }

    private func move(_ path: String, to newPath: String) throws(DataError) {
        let source = root.appending(path: path)
        let destination = root.appending(path: newPath)
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                moveError = error
            }
        }
        if let failure = coordinationError ?? moveError {
            throw .fileWriteFailed(name: displayName(newPath), reason: failure.localizedDescription)
        }
        for key in hashes.keys where key == path || key.hasPrefix(path + "/") {
            let renamed = newPath + key.dropFirst(path.count)
            hashes[renamed] = hashes.removeValue(forKey: key)
            documents[renamed] = documents.removeValue(forKey: key)
        }
    }

    private func removeItem(_ path: String) throws(DataError) {
        let url = root.appending(path: path)
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                removeError = error
            }
        }
        if let failure = coordinationError ?? removeError {
            throw .fileWriteFailed(name: displayName(path), reason: failure.localizedDescription)
        }
        for key in hashes.keys where key == path || key.hasPrefix(path + "/") {
            hashes[key] = nil
            documents[key] = nil
        }
    }

    private func currentHashes() -> [String: String] {
        var result: [String: String] = [:]
        guard
            let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            return result
        }
        let rootPath = root.path(percentEncoded: false)
        let ignored = Set((manifest?.ignore ?? []) + ["node_modules", ".git"])
        var count = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if ignored.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard name.hasSuffix(".bru") else { continue }
            count += 1
            if count > Self.maximumFiles { break }
            let full = url.standardizedFileURL.path(percentEncoded: false)
            guard full.hasPrefix(rootPath) else { continue }
            var relative = String(full.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            if let data = try? Data(contentsOf: url) { result[relative] = Self.hash(data) }
        }
        return result
    }

    private func displayName(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encodeFolder(_ settings: FolderSettings, name: String?, original: BruDocument?) throws(DataError)
        -> String
    {
        do {
            return try BruFolderCodec.encode(settings, name: name, preserving: original)
        } catch {
            throw .fileWriteFailed(name: "folder.bru", reason: error.errorDescription ?? "encode")
        }
    }

    static func write(_ data: Data, to url: URL, displayName: String) throws(DataError) {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) {
            target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let failure = coordinationError ?? writeError {
            throw .fileWriteFailed(name: displayName, reason: failure.localizedDescription)
        }
    }

    private func read(_ url: URL, displayName: String) throws(DataError) -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target, options: .mappedIfSafe) }
        }
        if let coordinationError {
            throw .fileReadFailed(name: displayName, reason: coordinationError.localizedDescription)
        }
        do {
            let data = try result.get()
            guard data.count <= BruDocument.maximumBytes else {
                throw DataError.fileReadFailed(name: displayName, reason: "larger than 1 MB")
            }
            return data
        } catch let error as DataError {
            throw error
        } catch {
            throw .fileReadFailed(name: displayName, reason: error.localizedDescription)
        }
    }
}
