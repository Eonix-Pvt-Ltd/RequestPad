import Foundation

/// Watches a collection folder tree for changes (P01.4) and emits one debounced event per burst of changes.
/// Uses `DispatchSource` vnode sources on each directory (a file write inside a directory updates it). Callers
/// compare content hashes (``FolderCollectionRepository/hasExternalChanges()``) to ignore RequestPad's own writes.
public final class FolderWatcher: @unchecked Sendable {
    // @unchecked: all mutable state (`sources`, `pendingWork`, `continuation`) is confined to `queue`.
    public static let maximumWatchedDirectories = 256
    public static let debounceInterval: DispatchTimeInterval = .milliseconds(250)

    private let root: URL
    private let queue = DispatchQueue(label: "lk.eonix.RequestPad.FolderWatcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingWork: DispatchWorkItem?
    private var continuation: AsyncStream<Void>.Continuation?

    public init(root: URL) {
        self.root = root
    }

    /// Starts watching and returns the event stream. Ends when `stop()` is called.
    public func events() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        queue.sync {
            self.continuation = continuation
            self.rebuildSources()
        }
        continuation.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    public func stop() {
        queue.async {
            self.pendingWork?.cancel()
            self.sources.forEach { $0.cancel() }
            self.sources.removeAll()
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    private func rebuildSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for directory in directories() {
            let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleEvent() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func scheduleEvent() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // New or removed subfolders change the set of directories to watch.
            self.rebuildSources()
            self.continuation?.yield()
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func directories() -> [URL] {
        var result = [root]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return result }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true { result.append(url) }
            if result.count >= Self.maximumWatchedDirectories { break }
        }
        return result
    }
}
