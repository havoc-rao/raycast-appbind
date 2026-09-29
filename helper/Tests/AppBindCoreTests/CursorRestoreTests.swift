import XCTest
@testable import AppBindCore

final class CursorRestoreTests: XCTestCase {
    func testFractionalTargetsAllowRoundingIncludingNegativeDisplays() {
        XCTAssertTrue(CursorRestore.isAtClick(Point(x: 1500, y: 61), target: Point(x: 1499.82, y: 61.39)))
        XCTAssertTrue(CursorRestore.isAtClick(Point(x: -1500, y: -61), target: Point(x: -1499.82, y: -61.39)))
        XCTAssertTrue(CursorRestore.isAtClick(Point(x: 1500, y: 61.5), target: Point(x: 1499.82, y: 61.39)))
    }
    func testDoesNotAcceptUnrelatedPositionsOrNonfiniteValues() {
        XCTAssertFalse(CursorRestore.isAtClick(Point(x: 1502, y: 61), target: Point(x: 1499.82, y: 61.39)))
        XCTAssertFalse(CursorRestore.isAtClick(Point(x: .nan, y: 0), target: Point(x: 0, y: 0)))
        XCTAssertFalse(CursorRestore.isAtClick(Point(x: 0, y: 0), target: Point(x: .infinity, y: 0)))
    }
}
