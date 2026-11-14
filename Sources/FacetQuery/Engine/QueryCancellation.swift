import Foundation

/// Cancellation of one evaluation. The engine cancels it when the awaiting task is cancelled; connectors that
/// block on the network register a handler (for example, SQL Server sends ATTENTION and closes the connection).
public final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [Int: () -> Void] = [:]
    private var nextHandle = 0
    static let threadKey = "Facet.QueryCancellation"

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let run = Array(handlers.values)
        handlers = [:]
        lock.unlock()
        for h in run { h() }
    }

    /// Run `handler` on cancel (at once when already cancelled). Returns a handle for `remove`.
    @discardableResult
    public func onCancel(_ handler: @escaping () -> Void) -> Int {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return -1 }
        nextHandle += 1
        handlers[nextHandle] = handler
        lock.unlock()
        return nextHandle
    }
    public func remove(_ handle: Int) { lock.lock(); handlers[handle] = nil; lock.unlock() }

    /// The cancellation of the evaluation running on this thread, if any.
    public static var current: QueryCancellation? { Thread.current.threadDictionary[threadKey] as? QueryCancellation }
}
