import Foundation
import XCTest
@testable import AppBindCore

final class CaptureCoreTests: XCTestCase {
    private func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

    // MARK: - Geometry.anchorPoint / offset round-trips

    func testAnchorPointsAndOffsetRoundTrip() throws {
        let windows: [Rect] = [
            Rect(x: 0, y: 0, width: 800, height: 600),
            Rect(x: -1920, y: -1080, width: 1920, height: 1080),
            Rect(x: 1280, y: 0, width: 800, height: 600),
            Rect(x: -400, y: 300, width: 320, height: 200),
        ]
        let offsets: [Point] = [Point(x: 0, y: 0), Point(x: -42, y: 76), Point(x: 100, y: -100), Point(x: -100000, y: 100000)]
        // Algebraic inverse: offset(from:) must reproduce the offset that produced the target,
        // independent of containment checks.
        for window in windows {
            for anchor in Anchor.allCases {
                for offset in offsets {
                    let base = Geometry.anchorPoint(window: window, anchor: anchor)
                    let target = Point(x: base.x + offset.x, y: base.y + offset.y)
                    let back = try Geometry.offset(from: target, window: window, anchor: anchor)
                    XCTAssertEqual(back.x, offset.x, accuracy: 0.000_001, "anchor \(anchor.rawValue)")
                    XCTAssertEqual(back.y, offset.y, accuracy: 0.000_001, "anchor \(anchor.rawValue)")
                }
            }
        }
        // End-to-end: offsets chosen to stay inside the window pass Geometry.target then invert.
        let window = Rect(x: 0, y: 0, width: 800, height: 600)
        let inWindow: [Anchor: [Point]] = [
            .topLeft: [Point(x: 20, y: 20), Point(x: 400, y: 120)],
            .topRight: [Point(x: -100, y: 50), Point(x: -400, y: 8)],
            .bottomLeft: [Point(x: 60, y: -40), Point(x: 260, y: -500)],
            .bottomRight: [Point(x: -80, y: -80), Point(x: -300, y: -240)],
            .center: [Point(x: 0, y: 0), Point(x: 251, y: -177)],
        ]
        for anchor in Anchor.allCases {
            for offset in inWindow[anchor]! {
                let point = try Geometry.target(window: window, anchor: anchor, offset: offset, displays: [window])
                let back = try Geometry.offset(from: point, window: window, anchor: anchor)
                XCTAssertEqual(back.x, offset.x, accuracy: 0.000_001, "e2e anchor \(anchor.rawValue)")
                XCTAssertEqual(back.y, offset.y, accuracy: 0.000_001, "e2e anchor \(anchor.rawValue)")
            }
        }
    }

    func testAnchorPointExactValues() {
        let window = Rect(x: 100, y: 200, width: 800, height: 400)
        XCTAssertEqual(Geometry.anchorPoint(window: window, anchor: .topLeft), Point(x: 100, y: 200))
        XCTAssertEqual(Geometry.anchorPoint(window: window, anchor: .topRight), Point(x: 900, y: 200))
        XCTAssertEqual(Geometry.anchorPoint(window: window, anchor: .bottomLeft), Point(x: 100, y: 600))
        XCTAssertEqual(Geometry.anchorPoint(window: window, anchor: .bottomRight), Point(x: 900, y: 600))
        XCTAssertEqual(Geometry.anchorPoint(window: window, anchor: .center), Point(x: 500, y: 400))
    }

    func testOffsetRejectsInvalidGeometry() {
        let window = Rect(x: 0, y: 0, width: 800, height: 600)
        assertCode("UNSAFE_TARGET") { _ = try Geometry.offset(from: Point(x: .nan, y: 0), window: window, anchor: .topLeft) }
        assertCode("UNSAFE_TARGET") { _ = try Geometry.offset(from: Point(x: 0, y: 0), window: Rect(x: 0, y: 0, width: 0, height: 600), anchor: .topLeft) }
        assertCode("UNSAFE_TARGET") { _ = try Geometry.offset(from: Point(x: 200_001, y: 0), window: window, anchor: .topLeft) }
        // Huge but finite window keeps arithmetic finite; absurd target beyond range is rejected.
        assertCode("UNSAFE_TARGET") { _ = try Geometry.offset(from: Point(x: 100_001, y: 0), window: window, anchor: .topLeft) }
    }

    private func assertCode(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? AppBindError)?.code, code, file: file, line: line)
        }
    }

    // MARK: - Coordinate conversion

    func testCocoaToCGConversion() {
        // Main display 1920x1080: Cocoa (0,0) bottom-left -> CG (0,1080) top-left.
        XCTAssertEqual(Coordinate.cgPoint(cocoaX: 0, cocoaY: 0, mainDisplayHeight: 1080), Point(x: 0, y: 1080))
        XCTAssertEqual(Coordinate.cgPoint(cocoaX: 100, cocoaY: 540, mainDisplayHeight: 1080), Point(x: 100, y: 540))
        XCTAssertEqual(Coordinate.cgPoint(cocoaX: -320, cocoaY: 1080, mainDisplayHeight: 1080), Point(x: -320, y: 0))
        let roundTrip = Coordinate.cocoaPoint(cgX: -320, cgY: 200, mainDisplayHeight: 1080)
        XCTAssertEqual(roundTrip.x, -320)
        XCTAssertEqual(roundTrip.y, 880)
    }

    func testOverlayFramesAndLocalCoordinatesAcrossDisplays() {
        let displays = [
            Rect(x: 0, y: 0, width: 1920, height: 1080),
            Rect(x: -1440, y: 180, width: 1440, height: 900),
            Rect(x: 200, y: -1200, width: 1600, height: 1200),
            Rect(x: 1920, y: 1080, width: 1280, height: 720),
        ]
        for display in displays {
            let frame = Coordinate.cocoaRect(display, mainDisplayHeight: 1080)
            XCTAssertEqual(frame.x, display.x)
            XCTAssertEqual(frame.y, 1080 - display.y - display.height)
            let target = Rect(x: display.x + 80, y: display.y + 60, width: 400, height: 300)
            let localRect = Coordinate.overlayRect(target, display: display)
            XCTAssertEqual(localRect, Rect(x: 80, y: display.height - 360, width: 400, height: 300))
            let point = Point(x: target.x + 15.5, y: target.y + 20.25)
            let local = Coordinate.overlayPoint(point, display: display)
            XCTAssertEqual(local, Point(x: 95.5, y: display.height - 80.25))
            XCTAssertEqual(Coordinate.cgPoint(cocoaX: frame.x + local.x, cocoaY: frame.y + local.y,
                                              mainDisplayHeight: 1080), point)
            XCTAssertTrue(localRect.contains(local))
        }
    }

    func testSpanningWindowUsesDisplayLocalOrigin() {
        let display = Rect(x: -1440, y: -200, width: 1440, height: 900)
        let window = Rect(x: -100, y: -100, width: 800, height: 600)
        XCTAssertEqual(Coordinate.overlayRect(window, display: display),
                       Rect(x: 1340, y: 200, width: 800, height: 600))
    }

    // MARK: - capture request parsing

    func testCaptureRequestAccepted() throws {
        let request = try Request.parse(encoded(["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app", "anchor": "top-right"]))
        XCTAssertEqual(request.command, .capture)
        XCTAssertEqual(request.captureBundleId, "com.example.app")
        XCTAssertEqual(request.captureAnchor, .topRight)
        XCTAssertNil(request.binding)
    }

    func testCaptureRequestRejectsMalformed() throws {
        let valid: [String: Any] = ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app", "anchor": "center"]
        let malformed: [[String: Any]] = [
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app", "anchor": "middle"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "single", "anchor": "center"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app\n", "anchor": "center"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app", "anchor": "center", "extra": 1],
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app", "anchor": "center", "config": ["schemaVersion": 1, "bindings": []]],
            ["protocolVersion": 2, "command": "capture", "bundleId": "com.example.app", "anchor": "center"],
        ]
        for input in malformed {
            XCTAssertThrowsError(try Request.parse(encoded(input))) { error in
                let code = (error as? AppBindError)?.code ?? ""
                XCTAssertTrue(code == "INVALID_REQUEST" || code == "UNSUPPORTED_VERSION", "unexpected \(code)")
            }
        }
        // status/inspect must not accept capture keys.
        XCTAssertThrowsError(try Request.parse(encoded(["protocolVersion": 1, "command": "status", "bundleId": "com.example.app"])))
    }

    func testDryRunAndExecuteStillRequireConfigAndBinding() throws {
        // Capture-only fields must not be accepted by dry-run/execute.
        for command in ["dry-run", "execute"] {
            let input: [String: Any] = ["protocolVersion": 1, "command": command, "bundleId": "com.example.app", "anchor": "top-left"]
            XCTAssertThrowsError(try Request.parse(encoded(input))) { error in
                XCTAssertEqual((error as? AppBindError)?.code, "INVALID_REQUEST")
            }
            let full: [String: Any] = [
                "protocolVersion": 1, "command": command,
                "config": ["schemaVersion": 1, "bindings": [[
                    "id": "test", "name": "Test", "enabled": true,
                    "application": ["bundleId": "com.example.app"],
                    "trigger": ["type": "hotkey", "key": "k", "modifiers": ["option", "control"], "scope": "frontmost-app"],
                    "action": ["type": "window-relative-click", "window": "focused", "anchor": "top-right", "offset": ["x": -42, "y": 76], "button": "left", "restoreCursor": true],
                ]]],
                "bindingId": "test",
            ]
            let request = try Request.parse(encoded(full))
            XCTAssertEqual(request.command.rawValue, command)
            XCTAssertNotNil(request.binding)
            XCTAssertNil(request.captureBundleId)
        }
    }
}