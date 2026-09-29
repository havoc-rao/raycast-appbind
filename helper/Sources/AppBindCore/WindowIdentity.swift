import Foundation

public struct WindowSnapshot: Sendable {
    public let id: Int
    public let pid: Int
    public let layer: Int
    public let alpha: Double
    public let frame: Rect
    public init(id: Int, pid: Int, layer: Int, alpha: Double, frame: Rect) {
        self.id = id; self.pid = pid; self.layer = layer; self.alpha = alpha; self.frame = frame
    }
}

public enum WindowIdentity {
    /// Caller must also verify AX hit ownership, focused AX identity across stages,
    /// and (for a missing AX ID) unique matching geometry in the app's AX window list.
    public static func resolve(pid: Int, frame: Rect, point: Point, triggerID: Int,
                               axID: Int?, windows: [WindowSnapshot]) throws -> Int {
        func refuse(_ reason: String) -> AppBindError { AppBindError("UNSAFE_TARGET", reason) }
        guard pid > 0, triggerID > 0, frame.isValid, frame.contains(point), !windows.isEmpty,
              windows.count <= 4096, windows.allSatisfy({ $0.id > 0 && $0.pid > 0 && $0.frame.isValid && $0.alpha.isFinite && (0...1).contains($0.alpha) }),
              Set(windows.map(\.id)).count == windows.count else { throw refuse("Invalid or duplicate CG window identity metadata.") }
        if let axID, axID != triggerID { throw refuse("AX window number differs from the window captured at shortcut time.") }
        let candidates = windows.filter { $0.pid == pid && $0.layer == 0 && $0.frame == frame && $0.alpha > 0 }
        if axID == nil && candidates.count != 1 { throw refuse("Missing AXWindowNumber and CG geometry is ambiguous; cannot identify a unique window.") }
        guard let target = candidates.first(where: { $0.id == triggerID }) else { throw refuse("Trigger window no longer matches the focused AX window geometry.") }
        guard let front = windows.first(where: { $0.alpha > 0 && $0.frame.contains(point) }), front.id == target.id else {
            throw refuse("Target point is covered by another CG window.")
        }
        return target.id
    }
}
