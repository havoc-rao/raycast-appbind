import AppKit
import ApplicationServices
import Carbon.HIToolbox
import AppBindCore

/// Best-effort guarded input, not an atomic transaction with WindowServer or an app.
/// Unsupported AX/CG metadata is a refusal, never a reason to weaken validation.
enum SafeClickExecutor {
    struct Target { let window: AXUIElement; let frame: Rect; let point: Point; let number: Int }
    static func execute(binding: Binding, pid: pid_t, keyCode: UInt16, triggerWindow: Int, triggeredAt: Date, guardState: ExecutionGuard, token: UInt64) -> String? {
        do {
            func live() throws {
                guard Date().timeIntervalSince(triggeredAt) < 4, guardState.valid(token), AXIsProcessTrusted(), CGPreflightListenEventAccess(), !IsSecureEventInputEnabled() else { throw AppBindError("CANCELLED", "Execution cancelled or permissions unavailable.") }
                let correct = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication.map { $0.processIdentifier == pid && $0.bundleIdentifier == binding.bundleId && !$0.isHidden && !$0.isTerminated } ?? false }
                guard correct, !binding.bundleId.lowercased().contains("raycast") else { throw AppBindError("CANCELLED", "Foreground application changed or is unsafe.") }
                for button in UInt32(0)...UInt32(31) { if CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: button)!) { throw AppBindError("CANCELLED", "A real mouse button is held.") } }
            }
            try live()
            guard Date().timeIntervalSince(triggeredAt) < 0.25 else { throw AppBindError("CANCELLED", "Trigger processing was delayed.") }
            let original = try target(binding, pid, triggerWindow: triggerWindow, check: live)
            guard original.number == triggerWindow else { throw AppBindError("CANCELLED", "Focused window changed since trigger.") }
            let cursor = CGEvent(source: nil)?.location
            guard let cursor else { throw AppBindError("UNSAFE_TARGET", "Cannot establish original cursor location.") }
            let deadline = Date().addingTimeInterval(2)
            while !released(keyCode) {
                try live(); guard Date() < deadline else { throw AppBindError("CANCELLED", "Trigger release timed out.") }
                Thread.sleep(forTimeInterval: 0.01)
            }
            try live()
            let checked = try target(binding, pid, triggerWindow: triggerWindow, check: live)
            guard CFEqual(original.window, checked.window), original.number == checked.number else { throw AppBindError("CANCELLED", "Focused window identity changed.") }
            guard CGEvent(source: nil)?.location == cursor else { throw AppBindError("CANCELLED", "User moved the pointer.") }
            let final = try target(binding, pid, triggerWindow: triggerWindow, check: live)
            guard CFEqual(checked.window, final.window), checked.number == final.number, checked.frame == final.frame, checked.point == final.point else { throw AppBindError("CANCELLED", "Window or geometry changed during final verification.") }
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: final.point.x, y: final.point.y), mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: final.point.x, y: final.point.y), mouseButton: .left) else { throw AppBindError("UNSAFE_TARGET", "Cannot construct paired events.") }
            for event in [down, up] { event.flags = []; event.setIntegerValueField(.eventSourceUserData, value: ServiceRuntime.eventTag); event.setIntegerValueField(.mouseEventClickState, value: 1) }
            try live()
            guard released(keyCode), CGEvent(source: nil)?.location == cursor else { throw AppBindError("CANCELLED", "Input changed immediately before posting.") }
            // No fallible operation between down/up: every posted down gets its up.
            guard guardState.postIfValid(token, {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }) else { throw AppBindError("CANCELLED", "Execution cancelled before posting.") }
            // Let real-input callbacks invalidate the token before optional restoration.
            Thread.sleep(forTimeInterval: 0.025)
            guard guardState.valid(token), released(keyCode) else {
                return "Click posted; cursor restoration skipped because input or service state changed."
            }
            guard let current = CGEvent(source: nil)?.location else {
                return "Click posted; cannot read cursor position for restoration."
            }
            // A fractional target may be rounded by WindowServer. Real mouse motion
            // still cancels the token even when it falls within this tolerance.
            if current == cursor { return nil }
            guard CursorRestore.isAtClick(Point(x: current.x, y: current.y), target: final.point) else {
                return "Click posted; cursor restoration skipped because the pointer is not at the expected click position."
            }
            do { try live() } catch {
                return "Click posted; cursor restoration cancelled: \((error as? AppBindError)?.message ?? "state changed")."
            }
            guard let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: cursor, mouseButton: .left) else {
                return "Click posted; cannot construct cursor restoration event."
            }
            restore.flags = []
            restore.setIntegerValueField(.eventSourceUserData, value: ServiceRuntime.eventTag)
            guard guardState.postIfValid(token, { restore.post(tap: .cghidEventTap) }) else {
                return "Click posted; cursor restoration cancelled by user input or service stop."
            }
            Thread.sleep(forTimeInterval: 0.025)
            guard guardState.valid(token), let restored = CGEvent(source: nil)?.location,
                  CursorRestore.isAtClick(Point(x: restored.x, y: restored.y), target: Point(x: cursor.x, y: cursor.y)) else {
                return "Click posted; cursor restoration event sent, but return to the original position could not be confirmed."
            }
            return nil
        } catch { return (error as? AppBindError)?.message ?? "Safety verification failed; execution refused." }
    }
    private static func released(_ keyCode: UInt16) -> Bool {
        guard !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) else { return false }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskAlphaShift]).isEmpty
    }
    private static func target(_ binding: Binding, _ pid: pid_t, triggerWindow: Int, check: () throws -> Void) throws -> Target {
        try check()
        func refuse(_ reason: String) -> AppBindError { AppBindError("UNSAFE_TARGET", reason) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let raw = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw refuse("Focused AX window is unavailable.") }
        let window = unsafeDowncast(raw, to: AXUIElement.self); AXUIElementSetMessagingTimeout(window, 0.2)
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { throw refuse("Focused window belongs to another process.") }
        guard attribute(window, kAXRoleAttribute) as? String == kAXWindowRole else { throw refuse("Focused AX element is not a window.") }
        guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { throw refuse("Focused window is not a supported standard window (AXSubrole).") }
        guard boolAttribute(window, kAXMinimizedAttribute) == false else { throw refuse("Window is minimized or AXMinimized is unavailable.") }
        guard boolAttribute(window, kAXModalAttribute) == false else { throw refuse("Window is modal or AXModal is unavailable.") }
        guard let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement], children.count <= 128 else { throw refuse("Window children cannot be safely inspected (AXChildren missing or over limit).") }
        if let sheets = attribute(window, "AXSheets") as? [AXUIElement], !sheets.isEmpty { throw refuse("Window has an attached sheet.") }
        for child in children {
            try check(); AXUIElementSetMessagingTimeout(child, 0.1)
            guard let role = attribute(child, kAXRoleAttribute) as? String else { throw refuse("A window child's AXRole is unavailable.") }
            guard role != kAXSheetRole else { throw refuse("Window contains a modal sheet.") }
        }
        guard let pos = attribute(window, kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(), let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { throw refuse("Window AX position or size is unavailable.") }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(pos, to: AXValue.self), .cgPoint, &p), AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &s) else { throw refuse("Window AX position or size has an unexpected type.") }
        let frame = Rect(x: p.x, y: p.y, width: s.width, height: s.height)
        let point = try Geometry.target(window: frame, anchor: binding.anchor, offset: binding.offset, displays: displays())
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit,
              AXUIElementGetPid(hit, &owner) == .success, owner == pid else { throw refuse("Target point AX hit-test failed or belongs to another application (possibly covered).") }
        AXUIElementSetMessagingTimeout(hit, 0.2)
        guard CFEqual(hit, window) || attribute(hit, kAXWindowAttribute).map({ CFEqual($0, window) }) == true else { throw refuse("Target point does not resolve to the focused AX window.") }
        let rawNumber = attribute(window, "AXWindowNumber")
        var axNumber: Int?
        if let rawNumber {
            guard CFGetTypeID(rawNumber) == CFNumberGetTypeID(), let number = rawNumber as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue > 0,
                  number.doubleValue <= Double(UInt32.max), number.doubleValue.rounded() == number.doubleValue else {
                throw refuse("AXWindowNumber exists but is invalid; fallback is not permitted.")
            }
            axNumber = number.intValue
        } else {
            // Geometry is not identity on its own. Require uniqueness on both AX and
            // CG sides in addition to the trigger ID, hit-test and CFEqual checks.
            guard let appWindows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
                  !appWindows.isEmpty, appWindows.count <= 128 else { throw refuse("Missing AXWindowNumber and AX window list cannot be verified.") }
            var matches: [AXUIElement] = []
            for item in appWindows {
                try check()
                AXUIElementSetMessagingTimeout(item, 0.1)
                var itemOwner: pid_t = 0
                guard AXUIElementGetPid(item, &itemOwner) == .success, itemOwner == pid,
                      let position = attribute(item, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                      let size = attribute(item, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else {
                    throw refuse("Missing AXWindowNumber and an AX window has unavailable ownership/geometry.")
                }
                var origin = CGPoint.zero, dimensions = CGSize.zero
                guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
                      AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else {
                    throw refuse("Invalid AX window geometry during identity fallback.")
                }
                let itemFrame = Rect(x: origin.x, y: origin.y, width: dimensions.width, height: dimensions.height)
                guard itemFrame.isValid else { throw refuse("Invalid AX window frame during identity fallback.") }
                if itemFrame == frame { matches.append(item) }
            }
            guard matches.count == 1, CFEqual(matches[0], window) else {
                throw refuse("Missing AXWindowNumber and AX window geometry is ambiguous.")
            }
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]], windows.count <= 4096 else { throw refuse("On-screen CG window list is unavailable or over limit.") }
        var snapshots: [WindowSnapshot] = []
        for entry in windows {
            try check()
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let alpha = entry[kCGWindowAlpha as String] as? Double,
                  let windowPID = entry[kCGWindowOwnerPID as String] as? Int,
                  let id = entry[kCGWindowNumber as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int else { throw refuse("An on-screen CG window has incomplete bounds/ownership metadata.") }
            snapshots.append(WindowSnapshot(id: id, pid: windowPID, layer: layer, alpha: alpha,
                                            frame: Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)))
        }
        let number = try WindowIdentity.resolve(pid: Int(pid), frame: frame, point: point,
                                               triggerID: triggerWindow, axID: axNumber, windows: snapshots)
        guard let current = attribute(app, kAXFocusedWindowAttribute), CFEqual(current, window) else { throw refuse("Focused AX window changed during verification.") }
        try check()
        return Target(window: window, frame: frame, point: point, number: number)
    }
}
