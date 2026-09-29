import XCTest
@testable import AppBindCore

final class ShortcutRecordingStateTests: XCTestCase {
    func testCandidateWaitsAndCanBeReplacedBeforeConfirmation() {
        var state = ShortcutRecordingState()
        XCTAssertFalse(state.canConfirm)
        XCTAssertEqual(state.receive(logicalKey: "a", modifiers: ["command"], keyCode: 0), .editing)
        XCTAssertTrue(state.canConfirm)
        XCTAssertEqual(state.displayText, "⌘A")
        XCTAssertEqual(state.receive(logicalKey: "9", modifiers: ["command", "shift", "option", "control"]), .editing)
        XCTAssertEqual(state.displayText, "⌃⌥⇧⌘9")
        let expected = RecordedShortcut(key: "9", modifiers: ["control", "option", "shift", "command"])
        XCTAssertEqual(state.confirm(), .confirmed(expected))
        XCTAssertFalse(state.canConfirm)
        XCTAssertEqual(state.receive(logicalKey: "b", modifiers: ["option"]), .confirmed(expected))
    }

    func testModifierPreviewPreservesCandidateAndRestoresItOnRelease() {
        var state = ShortcutRecordingState()
        state.receive(logicalKey: "a", modifiers: ["command"])
        let candidate = state.candidate
        for modifiers: Set<String> in [["shift"], ["command", "control", "option", "shift"], []] {
            XCTAssertEqual(state.receive(logicalKey: nil, modifiers: modifiers, isModifierOnly: true), .editing)
            XCTAssertEqual(state.candidate, candidate)
            XCTAssertTrue(state.canConfirm)
            XCTAssertEqual(state.displayText, modifiers.isEmpty ? "⌘A" : ShortcutRecording.display(modifiers: modifiers))
        }
        XCTAssertEqual(state.displayText, "⌘A")
    }

    func testModifierOnlyCannotCreateCandidate() {
        var state = ShortcutRecordingState()
        state.receive(logicalKey: nil, modifiers: ["command", "control"], isModifierOnly: true)
        XCTAssertEqual(state.displayText, "⌃⌘")
        XCTAssertNil(state.candidate)
        XCTAssertFalse(state.canConfirm)
        state.receive(logicalKey: nil, modifiers: [], isModifierOnly: true)
        XCTAssertEqual(state.displayText, "按下快捷键")
    }

    func testBothEnterKeysRequireCandidateAndConfirmOnlyWithoutModifiers() {
        for code: UInt16 in [36, 76] {
            var state = ShortcutRecordingState()
            XCTAssertEqual(state.receive(logicalKey: nil, modifiers: [], keyCode: code), .editing)
            XCTAssertEqual(state.feedback, .needsCandidate)
            XCTAssertFalse(state.canConfirm)
            state.receive(logicalKey: "a", modifiers: ["control"])
            XCTAssertEqual(state.receive(logicalKey: nil, modifiers: [], keyCode: code),
                           .confirmed(RecordedShortcut(key: "a", modifiers: ["control"])))
            for modifier in ["control", "option", "shift", "command", "unsupported"] {
                var modified = ShortcutRecordingState()
                modified.receive(logicalKey: "a", modifiers: ["command"])
                XCTAssertEqual(modified.receive(logicalKey: nil, modifiers: [modifier], keyCode: code), .editing)
                XCTAssertEqual(modified.feedback, .rejected)
                XCTAssertFalse(modified.canConfirm)
            }
        }
    }

    func testInvalidInputRevokesOldCandidateIncludingUnsupportedModifierOnly() {
        for (key, modifiers, modifierOnly): (String?, Set<String>, Bool) in [
            (" ", [], false), ("a", [], false), (nil, ["command"], false),
            ("å", ["option"], false), ("a", ["unsupported"], false),
            (nil, ["unsupported"], true)
        ] {
            var state = ShortcutRecordingState()
            state.receive(logicalKey: "a", modifiers: ["command"])
            XCTAssertEqual(state.receive(logicalKey: key, modifiers: modifiers, isModifierOnly: modifierOnly), .editing)
            XCTAssertEqual(state.feedback, .rejected)
            XCTAssertNil(state.candidate)
            XCTAssertFalse(state.canConfirm)
            state.receive(logicalKey: nil, modifiers: [], isModifierOnly: true)
            XCTAssertEqual(state.feedback, .rejected)
            XCTAssertEqual(state.confirm(), .editing)
            XCTAssertEqual(state.feedback, .needsCandidate)
            state.receive(logicalKey: "b", modifiers: ["option"])
            XCTAssertEqual(state.displayText, "⌥B")
            XCTAssertEqual(state.feedback, .candidate)
            XCTAssertTrue(state.canConfirm)
        }
    }

    func testEscapeCancelsRegardlessOfCandidateOrModifiers() {
        for hasCandidate in [false, true] {
            var state = ShortcutRecordingState()
            if hasCandidate { state.receive(logicalKey: "a", modifiers: ["command"]) }
            XCTAssertEqual(state.receive(logicalKey: nil, modifiers: ["unsupported"], keyCode: 53), .cancelled)
            XCTAssertFalse(state.canConfirm)
            XCTAssertEqual(state.confirm(), .cancelled)
        }
    }
}
