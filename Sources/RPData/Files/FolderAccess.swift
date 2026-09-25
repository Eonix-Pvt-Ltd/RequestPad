import Foundation

/// A folder location resolved from a bookmark.
public struct ResolvedBookmark: Sendable, Hashable {
    public var url: URL
    /// The bookmark still works but should be recreated (and saved) now (B3).
    public var isStale: Bool
}

/// Persists access to user-selected folders across launches with security-scoped bookmarks (B3, P01.1).
public protocol FolderAccess: Sendable {
    func makeBookmark(for url: URL) throws(DataError) -> Data
    func resolve(_ bookmark: Data) throws(DataError) -> ResolvedBookmark
    /// Starts security-scoped access; the returned token stops it when released or `stop()` is called.
    func beginAccess(to url: URL) -> ScopedAccess
}

/// Live implementation: `.withSecurityScope` bookmarks on macOS (App Sandbox), minimal bookmarks on iOS.
public struct SecurityScopedBookmarks: FolderAccess {
    public init() {}

    public func makeBookmark(for url: URL) throws(DataError) -> Data {
        let access = beginAccess(to: url)
        defer { access.stop() }
        do {
            #if os(macOS)
                return try url.bookmarkData(
                    options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
                return try url.bookmarkData(
                    options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
        } catch {
            throw .accessDenied(path: url.lastPathComponent)
        }
    }

    public func resolve(_ bookmark: Data) throws(DataError) -> ResolvedBookmark {
        var isStale = false
        do {
            #if os(macOS)
                let url = try URL(
                    resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                    bookmarkDataIsStale: &isStale)
            #else
                let url = try URL(
                    resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            #endif
            return ResolvedBookmark(url: url, isStale: isStale)
        } catch {
            throw .bookmarkUnresolvable(reason: (error as NSError).localizedDescription)
        }
    }

    public func beginAccess(to url: URL) -> ScopedAccess {
        ScopedAccess(url: url, started: url.startAccessingSecurityScopedResource())
    }
}

/// Balances `startAccessingSecurityScopedResource` with exactly one `stop` (also on deinit).
public final class ScopedAccess: @unchecked Sendable {
    // @unchecked: `isActive` is only mutated under `lock`.
    public let url: URL
    private let lock = NSLock()
    private var isActive: Bool

    init(url: URL, started: Bool) {
        self.url = url
        isActive = started
    }

    /// Whether the system granted a security scope (false for URLs that don't need one, e.g. in the container).
    public var didStartScope: Bool { lock.withLock { isActive } }

    public func stop() {
        let shouldStop = lock.withLock {
            defer { isActive = false }
            return isActive
        }
        if shouldStop { url.stopAccessingSecurityScopedResource() }
    }

    deinit { stop() }
}

/// Test double: bookmarks are the file path; access always succeeds.
public struct PathBookmarks: FolderAccess {
    public var staleBookmarks: Set<Data>

    public init(staleBookmarks: Set<Data> = []) {
        self.staleBookmarks = staleBookmarks
    }

    public func makeBookmark(for url: URL) throws(DataError) -> Data { Data(url.path(percentEncoded: false).utf8) }

    public func resolve(_ bookmark: Data) throws(DataError) -> ResolvedBookmark {
        let path = String(decoding: bookmark, as: UTF8.self)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw .bookmarkUnresolvable(reason: "missing")
        }
        return ResolvedBookmark(
            url: URL(filePath: path, directoryHint: .isDirectory), isStale: staleBookmarks.contains(bookmark))
    }

    public func beginAccess(to url: URL) -> ScopedAccess { ScopedAccess(url: url, started: false) }
}
