import XCTest
@testable import AppBindCore

final class WindowIdentityTests: XCTestCase {
    let frame = Rect(x: -800, y: 20, width: 700, height: 600)
    var point: Point { Point(x: -200, y: 70) }
    func window(_ id: Int = 10, pid: Int = 42, layer: Int = 0, alpha: Double = 1, frame: Rect? = nil) -> WindowSnapshot {
        WindowSnapshot(id: id, pid: pid, layer: layer, alpha: alpha, frame: frame ?? self.frame)
    }
    func resolve(_ windows: [WindowSnapshot], ax: Int? = nil, trigger: Int = 10) throws -> Int {
        try WindowIdentity.resolve(pid: 42, frame: frame, point: point, triggerID: trigger, axID: ax, windows: windows)
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
