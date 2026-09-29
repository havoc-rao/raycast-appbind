import Foundation

public enum CursorRestore {
    /// Allow at most one logical unit of WindowServer coordinate quantization.
    /// A separate real-input cancellation token must still be valid.
    public static func isAtClick(_ current: Point, target: Point) -> Bool {
        guard current.x.isFinite, current.y.isFinite, target.x.isFinite, target.y.isFinite else { return false }
        return abs(current.x - target.x) <= 1 && abs(current.y - target.y) <= 1
    }
}
