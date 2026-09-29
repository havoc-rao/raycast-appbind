import Foundation

public struct RecordedShortcut: Equatable, Sendable {
    public let key: String
    public let modifiers: [String]
}

/// Candidate selection is separate from confirmation. Invalid input always revokes
/// the previous candidate so an error cannot accidentally confirm an older shortcut.
public struct ShortcutRecordingState: Equatable, Sendable {
    public enum Feedback: Equatable, Sendable {
        case ready, candidate, rejected, needsCandidate
    }
    public enum Outcome: Equatable, Sendable {
        case editing, confirmed(RecordedShortcut), cancelled
    }

    public private(set) var candidate: RecordedShortcut?
    public private(set) var heldModifiers: Set<String> = []
    public private(set) var feedback: Feedback = .ready
    public private(set) var outcome: Outcome = .editing

    public init() {}

    public var canConfirm: Bool { candidate != nil && outcome == .editing }
    public var displayText: String {
        if !heldModifiers.isEmpty { return ShortcutRecording.display(modifiers: heldModifiers) }
        if let candidate { return ShortcutRecording.display(modifiers: Set(candidate.modifiers), key: candidate.key) }
        return "按下快捷键"
    }

    @discardableResult
    public mutating func confirm() -> Outcome {
        guard outcome == .editing else { return outcome }
        if let candidate { outcome = .confirmed(candidate) }
        else { feedback = .needsCandidate }
        return outcome
    }

    @discardableResult
    public mutating func receive(logicalKey: String?, modifiers: Set<String>,
                                 keyCode: UInt16? = nil, isModifierOnly: Bool = false) -> Outcome {
        guard outcome == .editing else { return outcome }
        if !isModifierOnly && keyCode == 53 {
            outcome = .cancelled
            return outcome
        }
        if !isModifierOnly && (keyCode == 36 || keyCode == 76) && modifiers.isEmpty {
            return confirm()
        }
        switch ShortcutRecording.evaluate(logicalKey: logicalKey, modifiers: modifiers, isModifierOnly: isModifierOnly) {
        case .waiting:
            heldModifiers = modifiers
        case .recorded(let shortcut):
            candidate = shortcut
            heldModifiers = []
            feedback = .candidate
        case .rejected:
            candidate = nil
            heldModifiers = []
            feedback = .rejected
        case .cancelled:
            outcome = .cancelled
        }
        return outcome
    }
}

/// Pure validation of an unmodified logical key, not a text-input/Option character.
public enum ShortcutRecording {
    public enum InputResult: Equatable, Sendable {
        case waiting, cancelled, rejected
        case recorded(RecordedShortcut)
    }

    public static let modifierOrder = ["control", "option", "shift", "command"]

    public static func display(modifiers: Set<String>, key: String? = nil) -> String {
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        return modifierOrder.filter(modifiers.contains).compactMap { symbols[$0] }.joined()
            + (key?.uppercased() ?? "")
    }

    public static func evaluate(logicalKey: String?, modifiers: Set<String>,
                                isEscape: Bool = false, isModifierOnly: Bool = false) -> InputResult {
        if isEscape { return .cancelled }
        guard modifiers.isSubset(of: Set(modifierOrder)) else { return .rejected }
        if isModifierOnly { return .waiting }
        guard !modifiers.isEmpty, let key = logicalKey, key.utf8.count == 1,
              let byte = key.utf8.first,
              (97...122).contains(byte) || (48...57).contains(byte) else { return .rejected }
        return .recorded(RecordedShortcut(key: key, modifiers: modifierOrder.filter(modifiers.contains)))
    }
}
