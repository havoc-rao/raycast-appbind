import Foundation
import XCTest
@testable import AppBindCore

final class ShortcutRecordingTests: XCTestCase {
    func testMinimalProtocolRequest() throws {
        let request = try Request.parse(Data(#"{"protocolVersion":1,"command":"record-shortcut"}"#.utf8))
        XCTAssertEqual(request.command, .recordShortcut)
        XCTAssertNil(request.binding)
        XCTAssertNil(request.captureBundleId)
        XCTAssertNil(request.captureAnchor)
    }

    func testRequestRejectsEveryExtraParameter() throws {
        for field in ["config", "bindingId", "bundleId", "anchor", "timeout", "key", "modifiers"] {
            let data = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "command": "record-shortcut", field: NSNull()])
            XCTAssertThrowsError(try Request.parse(data)) {
                XCTAssertEqual(($0 as? AppBindError)?.code, "INVALID_REQUEST", field)
            }
        }
    }

    func testMalformedProtocolRequests() {
        for json in [#"{"command":"record-shortcut"}"#, #"{"protocolVersion":true,"command":"record-shortcut"}"#,
                     #"{"protocolVersion":1,"command":["record-shortcut"]}"#] {
            XCTAssertThrowsError(try Request.parse(Data(json.utf8))) {
                XCTAssertEqual(($0 as? AppBindError)?.code, "INVALID_REQUEST")
            }
        }
        XCTAssertThrowsError(try Request.parse(Data(#"{"protocolVersion":2,"command":"record-shortcut"}"#.utf8))) {
            XCTAssertEqual(($0 as? AppBindError)?.code, "UNSUPPORTED_VERSION")
        }
    }

    func testAllKeysAndModifierCombinationsHaveStableOrder() {
        let order = ShortcutRecording.modifierOrder
        for key in "abcdefghijklmnopqrstuvwxyz0123456789" {
            for mask in 1..<16 {
                let expected = order.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                let result = ShortcutRecording.evaluate(logicalKey: String(key), modifiers: Set(expected.reversed()))
                guard case .recorded(let shortcut) = result else { XCTFail("Valid shortcut rejected"); continue }
                XCTAssertEqual(shortcut.key, String(key))
                XCTAssertEqual(shortcut.modifiers, expected)
            }
        }
    }

    func testInvalidInputsContinueRatherThanRecordOrCancel() {
        for key: String? in [nil, "", "A", "ab", "a\n", "å", "中", "!", " ", "\t", "😀"] {
            XCTAssertEqual(ShortcutRecording.evaluate(logicalKey: key, modifiers: ["option"]), .rejected)
        }
        XCTAssertEqual(ShortcutRecording.evaluate(logicalKey: "a", modifiers: []), .rejected)
        for unsupported in ["fn", "capsLock", "numericPad", "help", "unknown"] {
            XCTAssertEqual(ShortcutRecording.evaluate(logicalKey: "a", modifiers: ["command", unsupported]), .rejected)
        }
    }

    func testModifierOnlyWaitsAndEscapeCancels() {
        for modifiers: Set<String> in [[], ["command"], ["control", "shift", "option", "command"]] {
            XCTAssertEqual(ShortcutRecording.evaluate(logicalKey: nil, modifiers: modifiers, isModifierOnly: true), .waiting)
        }
        XCTAssertEqual(ShortcutRecording.evaluate(logicalKey: nil, modifiers: ["fn"], isModifierOnly: true), .rejected)
        XCTAssertEqual(ShortcutRecording.evaluate(logicalKey: nil, modifiers: [], isEscape: true), .cancelled)
        XCTAssertEqual(ShortcutRecording.evaluate(logicalKey: nil, modifiers: ["command", "fn"], isEscape: true), .cancelled)
    }
}
