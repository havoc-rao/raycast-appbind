import Foundation

public struct Point: Equatable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct Rect: Equatable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite && abs($0) <= 100_000 }
            && width > 0 && height > 0 && (x + width).isFinite && (y + height).isFinite
    }
    public func contains(_ point: Point) -> Bool {
        isValid && point.x.isFinite && point.y.isFinite && point.x >= x && point.y >= y
            && point.x < x + width && point.y < y + height
    }
}
public enum Geometry {
    /// Anchor base point in logical desktop coordinates (X-right, Y-down).
    public static func anchorPoint(window: Rect, anchor: Anchor) -> Point {
        switch anchor {
        case .topLeft: return Point(x: window.x, y: window.y)
        case .topRight: return Point(x: window.x + window.width, y: window.y)
        case .bottomLeft: return Point(x: window.x, y: window.y + window.height)
        case .bottomRight: return Point(x: window.x + window.width, y: window.y + window.height)
        case .center: return Point(x: window.x + window.width / 2, y: window.y + window.height / 2)
        }
    }

    /// Pure diagnostic calculation in logical desktop coordinates, X-right/Y-down.
    /// Display union containment is for the point, not the entire (possibly spanning) window.
    public static func target(window: Rect, anchor: Anchor, offset: Point, displays: [Rect]) throws -> Point {
        guard window.isValid, !displays.isEmpty, displays.allSatisfy(\.isValid),
              offset.x.isFinite, offset.y.isFinite, abs(offset.x) <= 100_000, abs(offset.y) <= 100_000 else {
            throw AppBindError("UNSAFE_TARGET", "Invalid window, display, or offset geometry.")
        }
        let base = anchorPoint(window: window, anchor: anchor)
        let point = Point(x: base.x + offset.x, y: base.y + offset.y)
        guard window.contains(point), displays.contains(where: { $0.contains(point) }) else {
            throw AppBindError("UNSAFE_TARGET", "Target is outside the window or active displays.")
        }
        return point
    }

    /// Inverse of `target`: the offset that places `target` relative to `anchor` on `window`.
    /// Validates finiteness of the window and target and the supported offset range only;
    /// containment checks are the caller's responsibility (capture validates before saving).
    public static func offset(from target: Point, window: Rect, anchor: Anchor) throws -> Point {
        guard window.isValid, target.x.isFinite, target.y.isFinite else {
            throw AppBindError("UNSAFE_TARGET", "Invalid window or target geometry.")
        }
        let base = anchorPoint(window: window, anchor: anchor)
        let offset = Point(x: target.x - base.x, y: target.y - base.y)
        guard offset.x.isFinite, offset.y.isFinite, abs(offset.x) <= 100_000, abs(offset.y) <= 100_000 else {
            throw AppBindError("UNSAFE_TARGET", "Offset exceeds the supported range.")
        }
        return offset
    }
}

/// Coordinate-space conversions that must stay pure for unit testing.
public enum Coordinate {
    /// Convert an NSEvent.mouseLocation point (Cocoa: origin at bottom-left of the main
    /// display, Y up) into the global CG logical space used everywhere else (origin at
    /// top-left, Y down). Never multiplies by any backing scale factor.
    public static func cgPoint(cocoaX: Double, cocoaY: Double, mainDisplayHeight: Double) -> Point {
        Point(x: cocoaX, y: mainDisplayHeight - cocoaY)
    }

    /// Global CG rectangle to an AppKit window frame (bottom-left origin).
    public static func cocoaRect(_ rect: Rect, mainDisplayHeight: Double) -> Rect {
        Rect(x: rect.x, y: mainDisplayHeight - rect.y - rect.height, width: rect.width, height: rect.height)
    }

    /// Global CG point to an unflipped overlay view's local coordinates.
    public static func overlayPoint(_ point: Point, display: Rect) -> Point {
        Point(x: point.x - display.x, y: display.y + display.height - point.y)
    }

    /// Global CG rectangle to an unflipped overlay view's local coordinates.
    public static func overlayRect(_ rect: Rect, display: Rect) -> Rect {
        Rect(x: rect.x - display.x, y: display.y + display.height - rect.y - rect.height,
             width: rect.width, height: rect.height)
    }

    /// Inverse of `cgPoint(cocoaX:cocoaY:mainDisplayHeight:)` for round-trip tests.
    public static func cocoaPoint(cgX: Double, cgY: Double, mainDisplayHeight: Double) -> (x: Double, y: Double) {
        (cgX, mainDisplayHeight - cgY)
    }
}
