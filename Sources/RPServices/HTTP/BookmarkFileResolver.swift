import Foundation
import RPData

/// Resolves multipart file references for both storage kinds (F01.4):
/// - `bookmark:<base64>` — a security-scoped bookmark to a file the user picked (works after relaunch in the sandbox);
/// - a path relative to the collection folder (folder collections, portable in git) or an absolute path.
public struct BookmarkFileResolver: FileReferenceResolver {
    public static let bookmarkPrefix = "bookmark:"
    let baseDirectory: URL?
    let folderAccess: any FolderAccess

    public init(baseDirectory: URL?, folderAccess: any FolderAccess) {
        self.baseDirectory = baseDirectory
        self.folderAccess = folderAccess
    }

    public func open(_ reference: String) throws(ServiceError) -> (url: URL, access: ScopedAccess?) {
        guard reference.hasPrefix(Self.bookmarkPrefix) else {
            return try PathFileResolver(baseDirectory: baseDirectory).open(reference)
        }
        guard let data = Data(base64Encoded: String(reference.dropFirst(Self.bookmarkPrefix.count))),
            let resolved = try? folderAccess.resolve(data)
        else { throw .fileUnavailable(name: String(localized: "the chosen file", bundle: .module)) }
        let access = folderAccess.beginAccess(to: resolved.url)
        guard FileManager.default.isReadableFile(atPath: resolved.url.path(percentEncoded: false)) else {
            access.stop()
            throw .fileUnavailable(name: resolved.url.lastPathComponent)
        }
        return (resolved.url, access)
    }

    /// The reference to store for a picked file: a relative path when it lies inside `baseDirectory`, otherwise a
    /// bookmark.
    public static func reference(for url: URL, baseDirectory: URL?, folderAccess: any FolderAccess) throws(DataError)
        -> String
    {
        if let baseDirectory {
            let base = baseDirectory.standardizedFileURL.path(percentEncoded: false)
            let path = url.standardizedFileURL.path(percentEncoded: false)
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return bookmarkPrefix + (try folderAccess.makeBookmark(for: url)).base64EncodedString()
    }

    /// A short name for display: the file name for paths and bookmarks.
    public static func displayName(for reference: String, folderAccess: any FolderAccess) -> String {
        guard reference.hasPrefix(bookmarkPrefix) else { return URL(filePath: reference).lastPathComponent }
        guard let data = Data(base64Encoded: String(reference.dropFirst(bookmarkPrefix.count))),
            let resolved = try? folderAccess.resolve(data)
        else { return String(localized: "Missing file", bundle: .module) }
        return resolved.url.lastPathComponent
    }
}
