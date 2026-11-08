import Foundation

/// Single-slot hand-off from a producer thread (WebRTC decode) to a serial consumer queue. A new item overwrites one
/// that hasn't been taken yet (counted as a drop), so a slow consumer adds at most one item of latency instead of
/// building a backlog.
public final class LatestFrameSlot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var item: T?
    private var drainScheduled = false
    public private(set) var dropped = 0

    public init() {}

    /// Stores `value`. Returns true if the caller must schedule a drain (none is pending).
    public func put(_ value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if item != nil { dropped += 1 }
        item = value
        if drainScheduled { return false }
        drainScheduled = true
        return true
    }

    /// Takes the newest item and allows the next `put` to schedule another drain.
    public func take() -> T? {
        lock.lock()
        defer { lock.unlock() }
        let value = item
        item = nil
        drainScheduled = false
        return value
    }

    public var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}
