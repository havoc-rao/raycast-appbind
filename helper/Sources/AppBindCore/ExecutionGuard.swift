import Foundation

/// Cancellation barrier: once cancel returns, no older token may enter a posting
/// section. Down/up must share one section; do not perform AX calls under the lock.
public final class ExecutionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    public init() {}
    public func cancel() { lock.lock(); generation &+= 1; lock.unlock() }
    public func token() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    public func valid(_ token: UInt64) -> Bool { self.token() == token }
    public func postIfValid(_ token: UInt64, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == token else { return false }; body(); return true
    }
}
