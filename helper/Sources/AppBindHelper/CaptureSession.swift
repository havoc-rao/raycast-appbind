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
    private var animStart = Date.distantPast
    private var animTimer: Timer?
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
        startAnimation()
    }

    /// Drives the gentle pulse effect (halo breathing, ring radius) at 30 fps while the
    /// overlay is up. Cheap full-window redraws; stopped in `finish()`.
    private func startAnimation() {
        animStart = Date()
        let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(animTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    @objc private func animTick(_: Timer) {
        guard outcome == nil else { return }
        redraw()
    }

    /// Seconds within the current animation cycle (0..1), for overlay pulse effects.
    var animationPhase: Double {
        let elapsed = Date().timeIntervalSince(animStart)
        return elapsed - elapsed.rounded(.down)
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
        animTimer?.invalidate()
        animTimer = nil
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
        let phase = session.animationPhase

        drawDim(in: full)
        drawVignette(in: full)

        // Keep the target window region (intersection with this display) undimmed.
        let target = Coordinate.overlayRect(session.windowRect, display: display)
        let targetRect = NSRect(x: target.x, y: target.y, width: target.width, height: target.height)
        let inter = full.intersection(targetRect)
        if !inter.isEmpty {
            drawCutout(inter, phase: phase)
        }

        // Picked point overlay, only on the display that contains it.
        let pick = session.pick
        if display.contains(pick) {
            let local = Coordinate.overlayPoint(pick, display: display)
            let point = NSPoint(x: local.x, y: local.y)
            drawGuides(at: point, in: full)
            drawCrosshair(at: point, phase: phase, insideWindow: inter.contains(point))
            drawMiniReadout(at: point, in: full)
        }

        drawBanner(in: full)
    }

    // MARK: - Mask

    /// Vertical dim: darkest at the top where the banner sits, lighter toward the bottom,
    /// so the target window region pops more than with the previous flat fill.
    private func drawDim(in full: NSRect) {
        guard let gradient = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.40),
            NSColor.black.withAlphaComponent(0.26),
        ]) else { return }
        gradient.draw(in: full, angle: -90)
    }

    /// Soft radial vignette that darkens the display edges, giving the mask depth.
    private func drawVignette(in full: NSRect) {
        guard let gradient = NSGradient(colorsAndLocations:
            (NSColor.black.withAlphaComponent(0.0), 0.0),
            (NSColor.black.withAlphaComponent(0.0), 0.62),
            (NSColor.black.withAlphaComponent(0.18), 1.0)) else { return }
        let center = NSPoint(x: full.midX, y: full.midY)
        gradient.draw(fromCenter: center, radius: 0, toCenter: center,
                      radius: max(full.width, full.height) * 0.72,
                      options: [.drawsAfterEndingLocation])
    }

    /// Rounded cutout for the target window, ring halo, crisp outside edge line and
    /// corner brackets that breathe with the animation phase.
    private func drawCutout(_ rect: NSRect, phase: Double) {
        let corner: CGFloat = 10
        let cutout = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

        // Punch the target-window region through the dim layer.
        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            context.compositingOperation = .copy
            NSColor.clear.setFill()
            cutout.fill()
            context.restoreGraphicsState()
        }

        // Layered halo rings drawn entirely outside the cutout (never paint over the
        // window content), breathing slowly via the animation phase.
        let wave = CGFloat(0.5 + 0.5 * sin(phase * 2 * .pi))
        drawAnnulus(outer: rect.insetBy(dx: -13, dy: -13), inner: rect, cornerInset: 13,
                    color: NSColor.systemYellow.withAlphaComponent(0.10 + 0.08 * wave))
        drawAnnulus(outer: rect.insetBy(dx: -6, dy: -6), inner: rect, cornerInset: 6,
                    color: NSColor.systemYellow.withAlphaComponent(0.16 + 0.10 * wave))

        // Crisp edge line hugging the outside of the cutout.
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: -0.75, dy: -0.75),
                                xRadius: corner + 0.75, yRadius: corner + 0.75)
        edge.lineWidth = 1.5
        NSColor.systemYellow.withAlphaComponent(0.95).setStroke()
        edge.stroke()

        // Corner brackets: a targeting-frame feel that also survives flat/no-glow rendering.
        let bracket: CGFloat = 16
        let inset: CGFloat = 5
        NSColor.systemYellow.withAlphaComponent(0.55 + 0.40 * wave).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        let b = bracket, o = inset
        // Bottom-left
        path.move(to: NSPoint(x: rect.minX - o, y: rect.minY - o + b))
        path.line(to: NSPoint(x: rect.minX - o, y: rect.minY - o))
        path.line(to: NSPoint(x: rect.minX - o + b, y: rect.minY - o))
        // Bottom-right
        path.move(to: NSPoint(x: rect.maxX + o, y: rect.minY - o + b))
        path.line(to: NSPoint(x: rect.maxX + o, y: rect.minY - o))
        path.line(to: NSPoint(x: rect.maxX + o - b, y: rect.minY - o))
        // Top-right
        path.move(to: NSPoint(x: rect.maxX + o, y: rect.maxY + o - b))
        path.line(to: NSPoint(x: rect.maxX + o, y: rect.maxY + o))
        path.line(to: NSPoint(x: rect.maxX + o - b, y: rect.maxY + o))
        // Top-left
        path.move(to: NSPoint(x: rect.minX - o, y: rect.maxY + o - b))
        path.line(to: NSPoint(x: rect.minX - o, y: rect.maxY + o))
        path.line(to: NSPoint(x: rect.minX - o + b, y: rect.maxY + o))
        path.stroke()
    }

    /// Filled ring between `inner` and `outer` using an even-odd path (paralleling the
    /// corner radius by `cornerInset` so the band keeps a constant width).
    private func drawAnnulus(outer: NSRect, inner: NSRect, cornerInset: CGFloat, color: NSColor) {
        let radius: CGFloat = 10
        let path = NSBezierPath(roundedRect: outer, xRadius: radius + cornerInset, yRadius: radius + cornerInset)
        path.append(NSBezierPath(roundedRect: inner, xRadius: radius, yRadius: radius))
        path.windingRule = .evenOdd
        color.setFill()
        path.fill()
    }

    // MARK: - Picked point

    /// Faint full-display hairlines at the picked position for alignment, like a scope.
    private func drawGuides(at p: NSPoint, in full: NSRect) {
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let guides = NSBezierPath()
        guides.lineWidth = 1
        guides.move(to: NSPoint(x: full.minX, y: p.y))
        guides.line(to: NSPoint(x: full.maxX, y: p.y))
        guides.move(to: NSPoint(x: p.x, y: full.minY))
        guides.line(to: NSPoint(x: p.x, y: full.maxY))
        guides.stroke()
    }

    /// Scope-style crosshair: glow underlay, gapped arms, center dot and a breathing
    /// outer ring. Turns yellow while the point sits inside the target window to hint
    /// that Enter/click will confirm.
    private func drawCrosshair(at p: NSPoint, phase: Double, insideWindow: Bool) {
        let accent = insideWindow ? NSColor.systemYellow : NSColor.white
        let wave = CGFloat(0.5 + 0.5 * sin(phase * 2 * .pi))

        // Soft dark underglow keeps the arms readable over bright content.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let glow = NSBezierPath()
        glow.lineWidth = 5
        glow.move(to: NSPoint(x: p.x - 18, y: p.y)); glow.line(to: NSPoint(x: p.x + 18, y: p.y))
        glow.move(to: NSPoint(x: p.x, y: p.y - 18)); glow.line(to: NSPoint(x: p.x, y: p.y + 18))
        glow.stroke()

        // Crisp arms with a center gap.
        let arm: CGFloat = 12, gap: CGFloat = 4
        accent.withAlphaComponent(0.95).setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        cross.move(to: NSPoint(x: p.x - arm, y: p.y)); cross.line(to: NSPoint(x: p.x - gap, y: p.y))
        cross.move(to: NSPoint(x: p.x + gap, y: p.y)); cross.line(to: NSPoint(x: p.x + arm, y: p.y))
        cross.move(to: NSPoint(x: p.x, y: p.y - arm)); cross.line(to: NSPoint(x: p.x, y: p.y - gap))
        cross.move(to: NSPoint(x: p.x, y: p.y + gap)); cross.line(to: NSPoint(x: p.x, y: p.y + arm))
        cross.stroke()

        // Breathing outer ring.
        let radius = 13 + 1.2 * wave
        accent.withAlphaComponent(0.35 + 0.45 * wave).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        ring.lineWidth = 1.5
        ring.stroke()

        // Center dot.
        accent.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
    }

    /// Compact pill right under the crosshair with the absolute CG coordinates,
    /// clamped inside the display.
    private func drawMiniReadout(at p: NSPoint, in full: NSRect) {
        let pick = session?.pick ?? Point(x: 0, y: 0)
        let text = String(format: "X %d · Y %d", Int(pick.x.rounded()), Int(pick.y.rounded())) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let size = text.size(withAttributes: attributes)
        let margin: CGFloat = 14
        var x = p.x + margin
        var y = p.y - size.height - margin
        if x + size.width + 16 > full.maxX { x = p.x - size.width - margin - 16 }
        if y < full.minY { y = p.y + margin + 4 }
        let pill = NSRect(x: x, y: y, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        text.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4), withAttributes: attributes)
    }

    // MARK: - Readout banner

    /// Top-center banner: anchor chip, live X/Y offset values and the hint line, on a
    /// shadowed rounded panel with a subtle accent border.
    private func drawBanner(in full: NSRect) {
        guard let session else { return }
        let offset = session.currentOffset() ?? Point(x: 0, y: 0)

        let anchorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.systemYellow,
        ]
        let coordinateLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62),
        ]
        let coordinateValueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78),
        ]

        func coordinate(_ label: String, _ value: Int) -> NSAttributedString {
            let string = NSMutableAttributedString()
            string.append(NSAttributedString(string: label + " ", attributes: coordinateLabelAttributes))
            string.append(NSAttributedString(string: String(value), attributes: coordinateValueAttributes))
            return string
        }

        let anchorText = session.anchorName as NSString
        let xText = coordinate("X", Int(offset.x.rounded()))
        let yText = coordinate("Y", Int(offset.y.rounded()))
        let hint = "点击 / Enter 确认 · Esc 取消 · 方向键微调（Shift = 10）" as NSString

        let anchorSize = anchorText.size(withAttributes: anchorAttributes)
        let xSize = xText.size()
        let ySize = yText.size()
        let hintSize = hint.size(withAttributes: hintAttributes)

        let chipWidth = anchorSize.width + 18
        let chipHeight = anchorSize.height + 10
        let line1Height = max(chipHeight, max(xSize.height, ySize.height))
        let spacing: CGFloat = 10
        let contentsWidth = chipWidth + spacing + xSize.width + spacing + ySize.width
        let panelWidth = max(contentsWidth, hintSize.width) + 32
        let panelHeight = 14 + line1Height + 10 + hintSize.height + 12
        let panel = NSRect(x: full.midX - panelWidth / 2, y: full.maxY - panelHeight - 14,
                           width: panelWidth, height: panelHeight)

        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
            context.restoreGraphicsState()
        }
        NSColor.systemYellow.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        border.lineWidth = 1
        border.stroke()

        // Anchor chip.
        let chip = NSRect(x: panel.minX + 14, y: panel.maxY - 14 - chipHeight, width: chipWidth, height: chipHeight)
        NSColor.systemYellow.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill()
        NSColor.systemYellow.withAlphaComponent(0.5).setStroke()
        let chipBorder = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
        chipBorder.lineWidth = 1
        chipBorder.stroke()
        anchorText.draw(at: NSPoint(x: chip.midX - anchorSize.width / 2, y: chip.midY - anchorSize.height / 2),
                        withAttributes: anchorAttributes)

        // Coordinate values.
        let line1Y = panel.maxY - 14 - line1Height
        let xOrigin = NSPoint(x: chip.maxX + spacing, y: line1Y + (line1Height - xSize.height) / 2)
        xText.draw(at: xOrigin)
        yText.draw(at: NSPoint(x: xOrigin.x + xSize.width + spacing, y: line1Y + (line1Height - ySize.height) / 2))

        // Hint, centered.
        hint.draw(at: NSPoint(x: panel.midX - hintSize.width / 2, y: panel.minY + 12), withAttributes: hintAttributes)
    }
}