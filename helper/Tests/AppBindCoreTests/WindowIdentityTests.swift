import XCTest
@testable import AppBindCore

final class WindowIdentityTests: XCTestCase {
    let frame = Rect(x: -800, y: 20, width: 700, height: 600)
    var point: Point { Point(x: -200, y: 70) }
    func window(_ id: Int = 10, pid: Int = 42, layer: Int = 0, alpha: Double = 1, frame: Rect? = nil, owner: String? = nil) -> WindowSnapshot {
        WindowSnapshot(id: id, pid: pid, layer: layer, alpha: alpha, frame: frame ?? self.frame, owner: owner)
    }
    /// 7 is the helper's own PID throughout these tests.
    func resolve(_ windows: [WindowSnapshot], ax: Int? = nil, trigger: Int = 10) throws -> Int {
        try WindowIdentity.resolve(pid: 42, frame: frame, point: point, triggerID: trigger, axID: ax, windows: windows, ownPID: 7)
    }
    func testMissingAXNumberAcceptsUniqueTriggerMapping() throws {
        XCTAssertEqual(try resolve([window()]), 10)
        XCTAssertEqual(try resolve([window()], ax: 10), 10)
    }
    func testMissingAXNumberRejectsAmbiguousSameAppGeometry() {
        XCTAssertThrowsError(try resolve([window(), window(11)]))
        XCTAssertEqual(try resolve([window(), window(11)], ax: 10), 10)
    }
    func testExplicitMismatchingNumberNeverFallsBack() {
        XCTAssertThrowsError(try resolve([window()], ax: 11))
        XCTAssertThrowsError(try resolve([window()], trigger: 11))
    }
    func testOccludersFromSameOtherAppAndOverlayAreRejected() {
        XCTAssertThrowsError(try resolve([window(11), window()]))
        XCTAssertThrowsError(try resolve([window(11, pid: 99), window()]))
        XCTAssertThrowsError(try resolve([window(11, pid: 99, layer: 20), window()]))
        XCTAssertEqual(try resolve([window(11, pid: 99, alpha: 0), window()]), 10)
    }
    func testOwnOverlayIsNeverTreatedAsAnOccluder() throws {
        // A refusal notice sits above the target on purpose; the next trigger must
        // not fail closed against the helper's own window.
        XCTAssertEqual(try resolve([window(11, pid: 7), window()]), 10)
        XCTAssertEqual(try resolve([window(12, pid: 7, layer: 1000), window(11, pid: 99, alpha: 0), window()]), 10)
    }
    func testOcclusionRefusalNamesTheCoveringWindow() {
        // Rectangle maths alone cannot distinguish a real occluder from a transparent
        // helper window, so the refusal has to identify the window that claimed the point.
        XCTAssertThrowsError(try resolve([window(11, pid: 99, owner: "CodeBuddy CN"), window()])) { error in
            let message = (error as? AppBindError)?.message ?? ""
            XCTAssertTrue(message.contains("CodeBuddy CN"), message)
            XCTAssertTrue(message.contains("pid 99"), message)
            XCTAssertTrue(message.contains("layer 0"), message)
        }
        XCTAssertThrowsError(try resolve([window(11, pid: 42, owner: "Same App"), window()], ax: 10)) { error in
            XCTAssertTrue(((error as? AppBindError)?.message ?? "").contains("the target app's own window"))
        }
        XCTAssertThrowsError(try resolve([window(11, pid: 99), window()])) { error in
            XCTAssertTrue(((error as? AppBindError)?.message ?? "").contains("unknown app"))
        }
    }
    func testMissingWrongOwnerAndMovedWindowFailClosed() {
        XCTAssertThrowsError(try resolve([]))
        XCTAssertThrowsError(try resolve([window(pid: 99)]))
        XCTAssertThrowsError(try resolve([window(frame: Rect(x: -801, y: 20, width: 700, height: 600))]))
        XCTAssertThrowsError(try resolve([window(layer: 1)]))
    }
    func testMalformedMetadataAndDuplicateIDsFailClosed() {
        XCTAssertThrowsError(try resolve([window(), window()]))
        XCTAssertThrowsError(try resolve([window(alpha: .nan)]))
        XCTAssertThrowsError(try resolve([window(alpha: 2)]))
        XCTAssertThrowsError(try resolve([window(0)]))
    }
}
