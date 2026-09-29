import Foundation

/// Pure pairing/cancellation model. A consumed physical down always owns its repeats/up,
/// even if permissions, configuration, or the foreground app change in between.
public struct ServiceKeyState: Sendable {
    public private(set) var consumed: Set<UInt16> = []
    public private(set) var generation: UInt64 = 0
    public private(set) var pending: String?
    public init() {}
    public mutating func cancel() { generation &+= 1; pending = nil }
    public mutating func receive(code: UInt16, down: Bool, repeatEvent: Bool, match: String?, enabled: Bool) -> (consume: Bool, trigger: String?) {
        if consumed.contains(code) {
            if !down { consumed.remove(code) }
            return (true, nil)
        }
        guard down else { return (false, nil) }
        if repeatEvent { return (false, nil) }
        guard enabled, let match else { cancel(); return (false, nil) }
        guard pending == nil else { cancel(); return (false, nil) }
        consumed.insert(code); pending = match
        return (true, match)
    }
    public mutating func finish() { pending = nil }
}
