import XCTest
import CoreGraphics
@testable import AppBindCore

final class ServiceModifierTests: XCTestCase {
    func testDeviceSpecificBitsDoNotPreventLogicalShortcutMatching() {
        let flags = CGEventFlags.maskCommand.union(.maskControl)
        for bits: UInt64 in [0, 1, 2, 8, 16, 32, 64, 128, 0xffff] {
            XCTAssertEqual(ServiceModifiers.names(flags.union(CGEventFlags(rawValue: bits))), ["command", "control"])
        }
        XCTAssertEqual(ServiceModifiers.names(flags.union(.maskNonCoalesced)), ["command", "control"])
    }
    func testUnsupportedIndependentModifiersRemainRejected() {
        for flag: CGEventFlags in [.maskSecondaryFn, .maskAlphaShift, .maskNumericPad, .maskHelp] {
            XCTAssertNil(ServiceModifiers.names(flag.union(.maskCommand)))
        }
    }
    func testReleaseDeviceBitsDoNotCountAsNewModifierPress() {
        let before = ServiceModifiers.logicalFlags(.maskCommand.union(.maskControl).union(CGEventFlags(rawValue: 9)))
        let after = ServiceModifiers.logicalFlags(.maskCommand.union(CGEventFlags(rawValue: 16)))
        XCTAssertTrue(after.subtracting(before).isEmpty)
        XCTAssertFalse(ServiceModifiers.logicalFlags(after.union(.maskShift)).subtracting(before).isEmpty)
    }
}
