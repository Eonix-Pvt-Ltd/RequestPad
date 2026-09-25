import Foundation

/// Runs recursive parsing work on a dedicated thread with a large stack, so recursion depth (bounded by each
/// parser's depth limit) never depends on the calling thread's stack — Swift concurrency threads have 512 KB,
/// and sanitizer builds inflate frames several times (ADR-0030). The caller blocks until the work finishes;
/// use only for user-initiated, bounded work such as importing a document.
enum LargeStack {
    static let stackSize = 8 * 1024 * 1024

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.set(work())
            done.signal()
        }
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        done.wait()
        return box.value
    }

    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        // @unchecked: `stored` is only accessed under `lock`.
        private let lock = NSLock()
        private var stored: T?
        var value: T? { lock.withLock { stored } }
        func set(_ newValue: T) { lock.withLock { stored = newValue } }
    }
}
