import AppKit
import Carbon.HIToolbox
import AppBindCore

/// Local first-responder input only: no AX, event taps, permission prompts or event posting.
@MainActor
final class ShortcutRecordingSession: NSObject, NSWindowDelegate {
    private var window: ShortcutRecordingWindow?
    private var timer: Timer?
    private var began = Date()
    private var lostFocusAt: Date?
    private var acquiredFocus = false
    private var result: RecordedShortcut?
    private var cancellation: String?
    private let timeout: TimeInterval
    private var recording = ShortcutRecordingState()
    private let shortcutLabel = NSTextField(labelWithString: "按下快捷键")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let confirmButton = NSButton(title: "确认", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    init(timeout: TimeInterval = 120) { self.timeout = timeout }
    private var finished: Bool { result != nil || cancellation != nil }

    func run() throws -> [String: Any] {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = ShortcutRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 290),
                                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "录制快捷键"
        panel.isReleasedWhenClosed = false
        panel.session = self
        panel.delegate = self
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        shortcutLabel.frame = NSRect(x: 24, y: 200, width: 512, height: 58)
        shortcutLabel.font = .systemFont(ofSize: 38, weight: .medium)
        shortcutLabel.alignment = .center
        panel.contentView?.addSubview(shortcutLabel)
        let instructions = NSTextField(wrappingLabelWithString:
            "按下 ⌃ Control / ⌥ Option / ⇧ Shift / ⌘ Command + 字母或数字。\n可继续按新组合覆盖；松开修饰键后按 Enter 或点击「确认」。Esc 或「取消」退出。")
        instructions.frame = NSRect(x: 24, y: 125, width: 512, height: 64)
        instructions.font = .systemFont(ofSize: 14)
        panel.contentView?.addSubview(instructions)
        hint.frame = NSRect(x: 24, y: 67, width: 512, height: 48)
        hint.font = .systemFont(ofSize: 14)
        panel.contentView?.addSubview(hint)
        for (button, x, action) in [(cancelButton, CGFloat(328), #selector(cancelClicked)),
                                     (confirmButton, CGFloat(436), #selector(confirmClicked))] {
            button.frame = NSRect(x: x, y: 20, width: 100, height: 32)
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            // Mouse controls only: all keyboard input belongs to the recorder.
            button.refusesFirstResponder = true
            button.keyEquivalent = ""
            panel.contentView?.addSubview(button)
        }
        render()
        panel.center()
        panel.makeFirstResponder(panel)
        window = panel
        panel.orderFrontRegardless()
        began = Date()
        // Poll both app and window focus: transient activation handoffs are allowed,
        // but never reactivate once focus was acquired and the user moved elsewhere.
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.async { [weak self] in self?.activate(attempts: 40) }
        app.run()
        cleanup()
        guard let result else { throw AppBindError("USER_CANCELLED", cancellation ?? "Shortcut recording ended without a result.") }
        return ["key": result.key, "modifiers": result.modifiers]
    }

    private func activate(attempts: Int) {
        guard !finished, !acquiredFocus else { return }
        if NSApp.isActive {
            window?.makeKeyAndOrderFront(nil)
            if window?.isKeyWindow == true { acquiredFocus = true; return }
        }
        guard attempts > 0 else { cancel("Shortcut recording window could not become active."); return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.activate(attempts: attempts - 1) }
    }

    @objc private func tick() {
        guard !finished else { return }
        let now = Date()
        if now.timeIntervalSince(began) >= timeout { cancel("Shortcut recording timed out."); return }
        if NSApp.isActive && window?.isKeyWindow == true {
            acquiredFocus = true
            lostFocusAt = nil
        } else if acquiredFocus {
            if lostFocusAt == nil { lostFocusAt = now }
            if let lostFocusAt, now.timeIntervalSince(lostFocusAt) >= 0.4 {
                cancel("Shortcut recording window lost focus.")
            }
        }
    }

    func receive(_ event: NSEvent) {
        guard !finished, NSApp.isActive, window?.isKeyWindow == true else { return }
        var modifiers = Set<String>()
        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Keypad Enter carries numericPad as a key classification, not a held modifier.
        if event.type == .keyDown && event.keyCode == 76 { flags.remove(.numericPad) }
        let supported: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        for (flag, name): (NSEvent.ModifierFlags, String) in [(.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command")] {
            if flags.contains(flag) { modifiers.insert(name) }
        }
        if !flags.subtracting(supported).isEmpty { modifiers.insert("unsupported") }
        let isModifierOnly = event.type == .flagsChanged
        let outcome = recording.receive(logicalKey: isModifierOnly ? nil : logicalKey(event.keyCode),
                                        modifiers: modifiers, keyCode: event.keyCode,
                                        isModifierOnly: isModifierOnly)
        handle(outcome)
    }

    private func handle(_ outcome: ShortcutRecordingState.Outcome) {
        switch outcome {
        case .editing: render()
        case .cancelled: cancel("Shortcut recording cancelled by the user.")
        case .confirmed(let shortcut): result = shortcut; finish()
        }
    }

    private func render() {
        shortcutLabel.stringValue = recording.displayText
        confirmButton.isEnabled = recording.canConfirm
        hint.textColor = .secondaryLabelColor
        switch recording.feedback {
        case .ready:
            hint.stringValue = "等待录制；仅按修饰键不会生成候选快捷键。"
        case .candidate:
            let candidate = recording.candidate!
            hint.stringValue = "当前候选：\(ShortcutRecording.display(modifiers: Set(candidate.modifiers), key: candidate.key))。尚未保存，可继续录制或确认。"
        case .rejected:
            hint.textColor = .systemRed
            hint.stringValue = "不支持此输入，已清除候选。请按至少一个修饰键 + a–z 或 0–9；不支持 Fn 等其它修饰键。"
        case .needsCandidate:
            hint.textColor = .systemRed
            hint.stringValue = "还没有可确认的快捷键，请先录制有效组合。"
        }
    }

    @objc private func confirmClicked() {
        guard !finished else { return }
        handle(recording.confirm())
    }

    @objc private func cancelClicked() {
        cancel("Shortcut recording cancelled by the user.")
    }

    /// Translate the hardware key through the active ASCII-capable layout, without
    /// Option/Shift/Control/Command or dead-key state. This preserves logical layout
    /// letters, works under IMEs, and never mistakes Option+A's å for the key itself.
    private func logicalKey(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0, length <= characters.count else { return nil }
        return String(utf16CodeUnits: characters, count: length).lowercased()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel("Shortcut recording cancelled by the user.")
        return false
    }

    private func cancel(_ message: String) {
        guard !finished else { return }
        cancellation = message
        finish()
    }
    private func finish() {
        cleanup()
        NSApp.stop(nil)
        // No synthetic wakeup event: the local event/timer returns directly to run().
    }
    private func cleanup() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
    }
}

@MainActor
private final class ShortcutRecordingWindow: NSWindow {
    weak var session: ShortcutRecordingSession?
    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Consume before responder dispatch, even if a control acquires first responder.
    // Do not call super for these events: that would dispatch the same input twice.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .flagsChanged {
            session?.receive(event)
            return
        }
        super.sendEvent(event)
    }
    // AppKit routes Command shortcuts here before sendEvent. Returning true keeps
    // consumed equivalents from being sent through the window a second time.
    // Consume even invalid
    // combinations so they never trigger standard menu/window actions.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        session?.receive(event)
        return true
    }
}
