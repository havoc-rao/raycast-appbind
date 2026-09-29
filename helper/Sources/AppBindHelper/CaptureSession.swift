import AppKit
import ApplicationServices
import CoreGraphics
import AppBindCore

/// One overlay point-picking session for the capture command.
///
/// Safety contract (see docs/CONTRACT.md "Capture"): no clicks, no real cursor movement,
/// no hiding/activating of other apps, no CGEvent posting. The only activation is this
/// helper itself after the explicit user gesture "pick point". The target window is read
/// live from AX at confirm time; client-provided geometry is never accepted. If any
/// precondition or confirm-time check fails, the session fails closed with a structured
/// error instead of guessing.
@MainActor
final class CaptureSession: NSObject {
    enum Outcome {
        case confirmed([String: Any])
        case failed(code: String, message: String)
    }

    private let bundleId: String
    private let anchor: Anchor
    private let timeout: TimeInterval

    private var overlays: [OverlayWindow] = []
    private var appRef: AXUIElement?
    private var windowRef: AXUIElement?
    private var targetPid: pid_t = 0
    private var targetFrame = Rect(x: 0, y: 0, width: 1, height: 1)
    private var displays: [Rect] = []
    private var selected = Point(x: 0, y: 0)
    private var timer: Timer?
    private var began = Date()
    private var becameActiveOnce = false
    private(set) var outcome: Outcome?

    init(bundleId: String, anchor: Anchor, timeout: TimeInterval = 120) {
        self.bundleId = bundleId
        self.anchor = anchor
        self.timeout = timeout
    }

    // MARK: - AX helpers (mirror main.swift diagnostics; no titles ever)

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return (value as! NSNumber).boolValue
    }

    private func windowFrame(_ window: AXUIElement) throws -> Rect {
        guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw AppBindError("UNSAFE_TARGET", "Window geometry is unavailable.")
        }
        let axPosition = unsafeDowncast(position, to: AXValue.self), axSize = unsafeDowncast(size, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(axPosition) == .cgPoint, AXValueGetType(axSize) == .cgSize,
              AXValueGetValue(axPosition, .cgPoint, &point), AXValueGetValue(axSize, .cgSize, &dimensions) else {
            throw AppBindError("UNSAFE_TARGET", "Unexpected AX geometry types.")
        }
        let frame = Rect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
        guard frame.isValid else { throw AppBindError("UNSAFE_TARGET", "Invalid window geometry.") }
        return frame
    }

    /// Fail-closed resolution of the target application's focused window.
    private func resolveTarget() throws -> (pid: pid_t, app: AXUIElement, window: AXUIElement, frame: Rect) {
        guard AXIsProcessTrusted() else {
            throw AppBindError("PERMISSION_DENIED", "Accessibility access is not granted to this helper. No permission prompt was requested.")
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first(where: { !$0.isTerminated }) else {
            throw AppBindError("APP_NOT_RUNNING", "Target application is not running.")
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let raw = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw AppBindError("UNSAFE_TARGET", "No accessible focused window for the target application. Activate its window first, then retry.")
        }
        let window = unsafeDowncast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 1)
        guard attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
              attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              boolAttribute(window, kAXMinimizedAttribute) == false,
              boolAttribute(window, kAXModalAttribute) == false else {
            throw AppBindError("UNSAFE_TARGET", "Target window is minimized, modal, or nonstandard.")
        }
        return (running.processIdentifier, app, window, try windowFrame(window))
    }

    // MARK: - Session

    /// Returns the confirmed capture payload or throws a structured error.
    func run() throws -> [String: Any] {
        let resolved = try resolveTarget()
        appRef = resolved.app
        windowRef = resolved.window
        targetPid = resolved.pid
        targetFrame = resolved.frame
        try presentOverlays()
        NSApp.run()
        switch outcome {
        case .confirmed(let data): return data
        case .failed(let code, let message): throw AppBindError(code, message)
        case nil: throw AppBindError("USER_CANCELLED", "Capture ended without a result.")
        }
    }

    private func presentOverlays() throws {
        displays = try activeDisplayRects()
        guard displays.contains(where: { $0.contains(pointerInCG()) }) else {
            throw AppBindError("UNSAFE_TARGET", "Pointer is outside all active displays.")
        }
        selected = pointerInCG()
        let nsapp = NSApplication.shared
        nsapp.setActivationPolicy(.accessory)
        for display in displays {
            let overlay = OverlayWindow(display: display, session: self)
            overlays.append(overlay)
            overlay.orderFrontRegardless()
        }
        // Activation happens inside the run loop: activating before the loop starts can
        // fail silently for a bare command-line app, which would leave the keyboard with
        // the app below the overlay. Poll until active; fail closed if activation cannot
        // be achieved so keys are never leaked to an unrelated app.
        DispatchQueue.main.async { [weak self] in self?.waitForActivation(attempts: 40) }
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        resetTimer()
    }

    @MainActor
    private func waitForActivation(attempts: Int) {
        guard outcome == nil else { return }
        if NSApp.isActive {
            becameActiveOnce = true
            overlays.first?.makeKey()
            return
        }
        guard attempts > 0 else {
            fail("USER_CANCELLED", "Capture overlay could not become active. Retry picking.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.waitForActivation(attempts: attempts - 1) }
    }

    private func activeDisplayRects() throws -> [Rect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 128 else {
            throw AppBindError("UNSAFE_TARGET", "Active display list is unavailable.")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count)), actual: UInt32 = 0
        guard CGGetActiveDisplayList(count, &ids, &actual) == .success, actual > 0, actual <= count else {
            throw AppBindError("UNSAFE_TARGET", "Active displays changed during query.")
        }
        let rects = ids.prefix(Int(actual)).map { id -> Rect in
            let r = CGDisplayBounds(id)
            return Rect(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height)
        }
        guard rects.allSatisfy(\.isValid) else { throw AppBindError("UNSAFE_TARGET", "Invalid display geometry.") }
        return rects
    }

    private func pointerInCG() -> Point {
        let p = NSEvent.mouseLocation
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return Coordinate.cgPoint(cocoaX: p.x, cocoaY: p.y, mainDisplayHeight: mainHeight)
    }

    private func resetTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: timeout, target: self, selector: #selector(timeoutFired(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func redraw() {
        overlays.forEach { $0.contentView?.needsDisplay = true }
    }

    // MARK: - Events

    func pointerMoved(_ event: NSEvent) {
        guard outcome == nil, let window = event.window else { return }
        // Consume the event synchronously, in the same coordinate space used for drawing.
        let point = window.convertPoint(toScreen: event.locationInWindow)
        selected = Coordinate.cgPoint(cocoaX: point.x, cocoaY: point.y,
                                      mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        resetTimer()
        redraw()
    }

    @objc private func timeoutFired(_: Timer) {
        fail("USER_CANCELLED", "Capture timed out.")
    }

    @objc private func appBecameActive(_: Notification) {
        becameActiveOnce = true
        overlays.first?.makeKey()
    }

    @objc private func appResigned(_: Notification) {
        // Transient resigns during the activation handoff must not cancel the pick;
        // only a sustained loss of focus after the overlay became active is a cancel.
        guard becameActiveOnce, outcome == nil else { return }
        let resignAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            // If focus came back within the grace window, keep picking; otherwise cancel.
            guard let self, self.outcome == nil, !NSApp.isActive else { return }
            _ = resignAt
            self.fail("USER_CANCELLED", "Capture window lost focus.")
        }
    }

    func keyDown(_ event: NSEvent) {
        resetTimer()
        switch event.keyCode {
        case 36, 76:
            confirm()
        case 53:
            fail("USER_CANCELLED", "Capture cancelled by the user.")
        case 123, 124, 125, 126:
            nudge(event)
        default:
            break
        }
    }

    /// Arrow keys move the picked point by 1 logical unit (Shift = 10) without moving the real cursor.
    private func nudge(_ event: NSEvent) {
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        var point = selected
        switch event.keyCode {
        case 123: point = Point(x: point.x - step, y: point.y)
        case 124: point = Point(x: point.x + step, y: point.y)
        case 125: point = Point(x: point.x, y: point.y + step) // Y down on screen
        case 126: point = Point(x: point.x, y: point.y - step)
        default: return
        }
        guard targetFrame.contains(point), displays.contains(where: { $0.contains(point) }) else { return }
        selected = point
        redraw()
    }

    func confirmClick() {
        // Keep the overlay up through mouse-up so neither half of the click leaks.
        // Confirm the displayed selection, including any keyboard nudges, just like Enter.
        confirm()
    }

    private func confirm() {
        guard outcome == nil else { return }
        do {
            // Re-read live AX geometry at confirm time; never accept cached or client geometry.
            var frame = targetFrame
            if let windowRef { frame = try windowFrame(windowRef) } else { throw AppBindError("INTERNAL_ERROR", "Missing target window reference.") }
            guard frame.isValid else { throw AppBindError("UNSAFE_TARGET", "Target window geometry is invalid.") }
            guard frame.contains(selected) else {
                throw AppBindError("UNSAFE_TARGET", "Picked point is outside the target window; move inside and press Enter.")
            }
            guard displays.contains(where: { $0.contains(selected) }) else {
                throw AppBindError("UNSAFE_TARGET", "Picked point is outside all active displays.")
            }
            let offset = try Geometry.offset(from: selected, window: frame, anchor: anchor)
            let data: [String: Any] = [
                "bundleId": bundleId,
                "pid": targetPid,
                "frame": ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height],
                "anchor": anchor.rawValue,
                "offset": ["x": offset.x, "y": offset.y],
                "target": ["x": selected.x, "y": selected.y],
                "durationMs": Int((Date().timeIntervalSince(began) * 1000).rounded()),
            ]
            outcome = .confirmed(data)
            finish()
        } catch {
            fail((error as? AppBindError)?.code ?? "INTERNAL_ERROR", (error as? AppBindError)?.message ?? String(describing: error))
        }
    }

    private func fail(_ code: String, _ message: String) {
        guard outcome == nil else { return }
        outcome = .failed(code: code, message: message)
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        NSApp.stop(nil)
    }

    // MARK: - Drawing state access

    func currentOffset() -> Point? {
        try? Geometry.offset(from: selected, window: targetFrame, anchor: anchor)
    }

    var pick: Point { selected }
    var anchorName: String { anchor.rawValue }
    var windowRect: Rect { targetFrame }
}

/// Borderless dimming window for one display. Keeps the target window area visible
/// with a highlight border, draws the crosshair and live readout, and owns keyboard
/// input for confirm/cancel/nudge while swallowing mouse clicks.
@MainActor
final class OverlayWindow: NSWindow {
    private let display: Rect
    weak var session: CaptureSession?

    init(display: Rect, session: CaptureSession) {
        self.display = display
        self.session = session
        let cocoa = Coordinate.cocoaRect(display, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let rect = NSRect(x: cocoa.x, y: cocoa.y, width: cocoa.width, height: cocoa.height)
        super.init(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        contentView = OverlayView(frame: NSRect(origin: .zero, size: rect.size), display: display, session: session)
        makeFirstResponder(contentView)
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class OverlayView: NSView {
    private let display: Rect
    weak var session: CaptureSession?

    init(frame: NSRect, display: Rect, session: CaptureSession) {
        self.display = display
        self.session = session
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        session?.keyDown(event)
    }

    private var pointerTrackingArea: NSTrackingArea?
    private var clickStarted = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        session?.pointerMoved(event)
    }

    override func mouseDragged(with event: NSEvent) {
        session?.pointerMoved(event)
    }

    override func mouseDown(with event: NSEvent) {
        clickStarted = true
    }

    override func mouseUp(with event: NSEvent) {
        guard clickStarted else { return }
        clickStarted = false
        session?.confirmClick()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        let full = bounds
        NSColor.black.withAlphaComponent(0.23).setFill()
        full.fill()

        // Keep the target window region (intersection with this display) undimmed.
        let target = Coordinate.overlayRect(session.windowRect, display: display)
        let targetRect = NSRect(x: target.x, y: target.y, width: target.width, height: target.height)
        let inter = full.intersection(targetRect)
        if !inter.isEmpty {
            if let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.compositingOperation = .copy
                NSColor.clear.setFill()
                inter.fill()
                context.restoreGraphicsState()
            }
            NSColor.systemYellow.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(rect: inter)
            border.lineWidth = 2
            border.stroke()
        }

        // Picked point: crosshair, only if it lies on this display.
        let pick = session.pick
        if display.contains(pick) {
            let local = Coordinate.overlayPoint(pick, display: display)
            let cross = NSBezierPath()
            cross.lineWidth = 1
            cross.move(to: NSPoint(x: local.x - 10, y: local.y))
            cross.line(to: NSPoint(x: local.x + 10, y: local.y))
            cross.move(to: NSPoint(x: local.x, y: local.y - 10))
            cross.line(to: NSPoint(x: local.x, y: local.y + 10))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            cross.stroke()
        }

        // Readout banner pinned to the top of this display.
        let offset = session.currentOffset() ?? Point(x: 0, y: 0)
        let banner = "\(session.anchorName)   X \(Int(offset.x.rounded()))   Y \(Int(offset.y.rounded()))" as NSString
        let hint = "点击 / Enter 确认 · Esc 取消 · 方向键微调（Shift = 10）" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let bannerSize = banner.size(withAttributes: attributes)
        let hintSize = hint.size(withAttributes: hintAttributes)
        let panelWidth = max(bannerSize.width, hintSize.width) + 32
        let panelHeight = bannerSize.height + hintSize.height + 20
        let panel = NSRect(x: full.midX - panelWidth / 2, y: full.maxY - panelHeight - 10, width: panelWidth, height: panelHeight)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).fill()
        banner.draw(at: NSPoint(x: panel.minX + 16, y: panel.maxY - bannerSize.height - 8), withAttributes: attributes)
        hint.draw(at: NSPoint(x: panel.minX + 16, y: panel.minY + 8), withAttributes: hintAttributes)
    }
}