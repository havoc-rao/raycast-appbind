import Foundation

public struct WindowSnapshot: Sendable {
    public let id: Int
    public let pid: Int
    public let layer: Int
    public let alpha: Double
    public let frame: Rect
    /// Localized application name for `pid` when the caller can resolve it. Diagnostics
    /// only: identity and occlusion decisions never depend on it.
    public let owner: String?
    public init(id: Int, pid: Int, layer: Int, alpha: Double, frame: Rect, owner: String? = nil) {
        self.id = id; self.pid = pid; self.layer = layer; self.alpha = alpha; self.frame = frame; self.owner = owner
    }
}

public enum WindowIdentity {
    /// Caller must also verify AX hit ownership, focused AX identity across stages,
    /// and (for a missing AX ID) unique matching geometry in the app's AX window list.
    ///
    /// Windows owned by `ownPID` are dropped before any check: the helper's own
    /// overlays (the capture UI and the refusal notice) are deliberately drawn above
    /// the target, so counting them would make every retry while a notice is visible
    /// fail closed against an occluder the user cannot dismiss or act on.
    public static func resolve(pid: Int, frame: Rect, point: Point, triggerID: Int,
                               axID: Int?, windows: [WindowSnapshot], ownPID: Int) throws -> Int {
        func refuse(_ reason: String) -> AppBindError { AppBindError("UNSAFE_TARGET", reason) }
        let windows = windows.filter { $0.pid != ownPID }
        guard pid > 0, triggerID > 0, frame.isValid, frame.contains(point), !windows.isEmpty,
              windows.count <= 4096, windows.allSatisfy({ $0.id > 0 && $0.pid > 0 && $0.frame.isValid && $0.alpha.isFinite && (0...1).contains($0.alpha) }),
              Set(windows.map(\.id)).count == windows.count else { throw refuse("Invalid or duplicate CG window identity metadata.") }
        if let axID, axID != triggerID { throw refuse("AX window number differs from the window captured at shortcut time.") }
        let candidates = windows.filter { $0.pid == pid && $0.layer == 0 && $0.frame == frame && $0.alpha > 0 }
        if axID == nil && candidates.count != 1 { throw refuse("Missing AXWindowNumber and CG geometry is ambiguous; cannot identify a unique window.") }
        guard let target = candidates.first(where: { $0.id == triggerID }) else { throw refuse("Trigger window no longer matches the focused AX window geometry.") }
        let front = windows.first(where: { $0.alpha > 0 && $0.frame.contains(point) })
        guard let front, front.id == target.id else {
            // Naming the covering window is the only way to tell a genuine occluder from
            // a rectangle that merely overlaps the point (rounded corner, transparent
            // helper window, or the target app's own popup). Rectangle maths alone cannot.
            throw refuse("Target point is covered by another CG window: \(describe(front, targetPID: pid)).")
        }
        return target.id
    }

    /// `nil` means no window claimed the point at all, which the guard above reports the
    /// same way; the difference matters only for the stated reason.
    private static func describe(_ front: WindowSnapshot?, targetPID: Int) -> String {
        guard let front else { return "no on-screen window claims the point" }
        let owner = front.owner ?? "unknown app"
        let same = front.pid == targetPID ? ", the target app's own window" : ""
        return "\(owner) (pid \(front.pid), layer \(front.layer)\(same), \(format(front.frame)))"
    }

    private static func format(_ frame: Rect) -> String {
        "\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))×\(Int(frame.height))"
    }
}
