import AppKit
import ApplicationServices
import Carbon.HIToolbox
import AppBindCore

@MainActor
final class ServiceRuntime {
    let directory: ServiceDirectory
    private var bindings: [Binding] = []
    private var digest: String?
    private var lastError: String?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var keys = ServiceKeyState()
    private let guardState = ExecutionGuard()
    private let queue = DispatchQueue(label: "appbind.safe-executor")
    private var active = false
    private var suspended = false
    // Secure Input is a temporary safety gate, not a latched runtime fault.
    private var secureInputPaused = false
    private var pauseReason: String?
    private var logicalKeys: [UInt16: String] = [:]
    private var foregroundPID: pid_t = 0
    private var foregroundBundle: String?
    private var previousFlags: CGEventFlags = []
    private var busy = false
    nonisolated static let eventTag: Int64 = 0x41505042494e44
    init(directory: ServiceDirectory) { self.directory = directory }
    func start() {
        active = true
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(); self?.updateForeground() }
        }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    func stop() {
        active = false; cancel(); timer?.invalidate(); timer = nil
        // Drain owned key-up/repeats without accepting new triggers. No synthetic
        // key compensation; after this bounded grace period pairing is best effort.
        let deadline = Date().addingTimeInterval(0.5)
        while !keys.consumed.isEmpty && Date() < deadline {
            guard let tap, CGEvent.tapIsEnabled(tap: tap) else { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    func cancel() { keys.cancel(); guardState.cancel() }
    private var permitted: Bool { AXIsProcessTrusted() && CGPreflightListenEventAccess() && !IsSecureEventInputEnabled() }
    private var enabled: Bool { active && !suspended && !secureInputPaused && digest != nil && tap.map { CGEvent.tapIsEnabled(tap: $0) } == true && permitted }
    func status() -> [String: Any] {
        tick()
        return ["running": active, "executionEnabled": enabled, "accessibilityTrusted": AXIsProcessTrusted(), "inputMonitoringTrusted": CGPreflightListenEventAccess(), "enabledBindings": bindings.filter(\.enabled).count, "configDigest": digest as Any? ?? NSNull(), "lastError": (pauseReason ?? lastError) as Any? ?? NSNull(), "pid": getpid()]
    }
    func reload() {
        cancel(); bindings = []; digest = nil; suspended = false; pauseReason = nil
        do { let (config, hash) = try directory.configuration(); bindings = config.bindings; digest = hash; lastError = nil }
        catch { lastError = (error as? AppBindError)?.message ?? "Configuration could not be loaded." }
        updateForeground(); refreshLayout()
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CFMachPortInvalidate(tap)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            self.tap = nil; source = nil
        }
        if active && permitted && digest != nil && tap == nil { installTap() }
    }
    private func updateForeground() {
        let app = NSWorkspace.shared.frontmostApplication
        foregroundPID = app?.processIdentifier ?? 0; foregroundBundle = app?.bundleIdentifier
    }
    private func tick() {
        guard active else { return }
        let permissions = AXIsProcessTrusted() && CGPreflightListenEventAccess()
        let secureInput = IsSecureEventInputEnabled()
        if !permissions {
            cancel(); suspended = true
            lastError = "辅助功能或输入监控权限不可用；授权后请重载规则。"
        }
        if secureInput {
            if !secureInputPaused { cancel() }
            secureInputPaused = true
            pauseReason = "安全输入开启，已临时暂停；结束后将自动恢复，无需重启。"
        } else {
            let recoveringSecureInput = secureInputPaused
            if secureInputPaused {
                // Never revive a pre-pause execution token or queued click.
                cancel(); updateForeground(); refreshLayout()
            }
            secureInputPaused = false; pauseReason = nil
            // Secure Input can disable the existing tap. Re-enable only while
            // permissions/config remain valid and no unrelated fault is latched.
            if recoveringSecureInput && permissions && !suspended && digest != nil {
                if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
                if tap == nil { installTap() }
            }
            if let tap, !CGEvent.tapIsEnabled(tap: tap) {
                cancel(); suspended = true
                lastError = "事件监听已禁用；请重载规则或重启服务。"
            }
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundPID { cancel(); updateForeground() }
        refreshLayout()
    }
    private func installTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let consumed = MainActor.assumeIsolated { Unmanaged<ServiceRuntime>.fromOpaque(context).takeUnretainedValue().receive(type, event) == nil }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { suspended = true; lastError = "Cannot create event tap; no execution enabled."; return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventTag { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            if secureInputPaused || IsSecureEventInputEnabled() {
                secureInputPaused = true
                pauseReason = "安全输入开启，已临时暂停；结束后将自动恢复，无需重启。"
            } else {
                suspended = true; lastError = "事件监听已禁用；请重载规则或重启服务。"
            }
            return Unmanaged.passUnretained(event)
        }
        let logicalFlags = ServiceModifiers.logicalFlags(event.flags)
        if type == .flagsChanged {
            if !logicalFlags.subtracting(previousFlags).isEmpty { cancel() }
            previousFlags = logicalFlags
            return Unmanaged.passUnretained(event)
        }
        previousFlags = logicalFlags
        let app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier != foregroundPID || app?.bundleIdentifier != foregroundBundle { cancel(); updateForeground() }
        guard type == .keyDown || type == .keyUp else { cancel(); return Unmanaged.passUnretained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = ServiceModifiers.names(event.flags)
        let match = modifiers.flatMap { names in bindings.first { $0.enabled && $0.bundleId == foregroundBundle && $0.key == logicalKeys[code] && $0.modifiers == names } }
        let outcome = keys.receive(code: code, down: type == .keyDown, repeatEvent: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, match: match?.id, enabled: enabled && !busy)
        if type == .keyDown && !outcome.consume { guardState.cancel() }
        if outcome.trigger != nil, let binding = match {
            // Non-AX WindowServer snapshot at trigger time. The worker must map its
            // focused AX window to this exact public CG ID, not just the same PID.
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                  let frontWindow = windows.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
                  frontWindow[kCGWindowOwnerPID as String] as? Int == Int(foregroundPID),
                  let triggerWindow = frontWindow[kCGWindowNumber as String] as? Int else { lastError = "Shortcut matched, but the frontmost CG window could not be verified for the target application."; cancel(); return outcome.consume ? nil : Unmanaged.passUnretained(event) }
            busy = true
            let triggeredAt = Date()
            let pid = foregroundPID, token = guardState.token(), guardState = self.guardState
            queue.async { [weak self] in
                let error = SafeClickExecutor.execute(binding: binding, pid: pid, keyCode: code, triggerWindow: triggerWindow, triggeredAt: triggeredAt, guardState: guardState, token: token)
                DispatchQueue.main.async { self?.busy = false; self?.keys.finish(); if let error { self?.lastError = error } }
            }
        }
        return outcome.consume ? nil : Unmanaged.passUnretained(event)
    }
    private func refreshLayout() {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(), let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { logicalKeys = [:]; cancel(); return }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { logicalKeys = [:]; cancel(); return }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var result: [UInt16: String] = [:]
        for code in UInt16(0)...UInt16(127) {
            var dead: UInt32 = 0, length = 0; var chars = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars) == noErr && length > 0 && length <= chars.count { result[code] = String(utf16CodeUnits: chars, count: length).lowercased() }
        }
        if result != logicalKeys { cancel(); logicalKeys = result }
    }
}
