import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import AppBindCore

// Deliberately no prompting, event APIs, app activation, or cursor operations.
@MainActor
func frontmost(expectedBundle: String? = nil) throws -> (bundle: String, pid: pid_t, window: AXUIElement, frame: Rect) {
    guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else {
        throw AppBindError("NO_FRONTMOST_APP", "No identifiable frontmost application.")
    }
    guard !bundle.lowercased().hasPrefix("com.raycast."), bundle.lowercased() != "com.raycast" else {
        throw AppBindError("UNSAFE_TARGET", "Raycast is frontmost. Focus the target application and retry; this helper never hides or activates apps.")
    }
    if let expectedBundle, bundle != expectedBundle { throw AppBindError("APP_MISMATCH", "Frontmost application does not match the binding.") }
    guard AXIsProcessTrusted() else { throw AppBindError("PERMISSION_DENIED", "Accessibility access is not granted to this helper. No permission prompt was requested.") }
    guard !app.isHidden, !app.isTerminated else { throw AppBindError("UNSAFE_TARGET", "Frontmost application is unavailable or hidden.") }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 1)
    guard let rawWindow = attribute(application, kAXFocusedWindowAttribute), CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
        throw AppBindError("UNSAFE_TARGET", "No accessible focused window.")
    }
    let window = unsafeDowncast(rawWindow, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(window, 1)
    guard attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
          attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
          boolAttribute(window, kAXMinimizedAttribute) == false,
          boolAttribute(window, kAXModalAttribute) == false else {
        throw AppBindError("UNSAFE_TARGET", "Window is minimized, modal, nonstandard, or safety attributes are unavailable.")
    }
    // Sheets can be attached to a standard window even while its modal flag is false.
    if let sheets = attribute(window, "AXSheets") as? [Any], !sheets.isEmpty {
        throw AppBindError("UNSAFE_TARGET", "Window has an attached sheet.")
    }
    if let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] {
        guard children.count <= 1024 else { throw AppBindError("UNSAFE_TARGET", "Window child list exceeds diagnostic limits.") }
        for child in children where attribute(child, kAXRoleAttribute) as? String == kAXSheetRole {
            throw AppBindError("UNSAFE_TARGET", "Window has an attached sheet.")
        }
    }
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
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          let current = attribute(application, kAXFocusedWindowAttribute), CFEqual(current, window) else {
        throw AppBindError("UNSAFE_TARGET", "Focus changed during diagnostic query.")
    }
    return (bundle, app.processIdentifier, window, frame)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return (value as! NSNumber).boolValue
}
func displays() throws -> [Rect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 128 else {
        throw AppBindError("UNSAFE_TARGET", "Active display list is unavailable.")
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count)), actual: UInt32 = 0
    guard CGGetActiveDisplayList(count, &ids, &actual) == .success, actual > 0, actual <= count else {
        throw AppBindError("UNSAFE_TARGET", "Active displays changed during query.")
    }
    return ids.prefix(Int(actual)).map {
        let r = CGDisplayBounds($0)
        return Rect(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height)
    }
}
func frameJSON(_ r: Rect) -> [String: Double] { ["x": r.x, "y": r.y, "width": r.width, "height": r.height] }

@MainActor
func handle(_ request: Request) throws -> [String: Any] {
    switch request.command {
    case .status:
        return ["helperVersion": "0.1.0", "accessibilityTrusted": AXIsProcessTrusted(), "executionEnabled": false]
    case .execute:
        throw AppBindError("SAFETY_NOT_IMPLEMENTED", "Execution is disabled: persistent target identity, occlusion and user-intervention safety are not implemented. No input events were posted.")
    case .inspect:
        let target = try frontmost()
        return ["bundleId": target.bundle, "pid": target.pid, "frame": frameJSON(target.frame), "diagnosticOnly": true]
    case .dryRun:
        guard let binding = request.binding else { throw AppBindError("INTERNAL_ERROR", "Missing validated binding.") }
        let target = try frontmost(expectedBundle: binding.bundleId)
        let point = try Geometry.target(window: target.frame, anchor: binding.anchor, offset: binding.offset, displays: displays())
        return ["bindingId": binding.id, "bundleId": target.bundle, "pid": target.pid, "frame": frameJSON(target.frame),
                "target": ["x": point.x, "y": point.y], "diagnosticOnly": true]
    case .recordShortcut:
        return try ShortcutRecordingSession().run()
    case .capture:
        guard let bundleId = request.captureBundleId, let anchor = request.captureAnchor else {
            throw AppBindError("INTERNAL_ERROR", "Missing validated capture identity.")
        }
        return try CaptureSession(bundleId: bundleId, anchor: anchor).run()
    }
}

// Bounded streaming read: one extra byte distinguishes an oversized request.
func readRequest() throws -> Data {
    var data = Data()
    while data.count <= Config.maxBytes {
        let remaining = Config.maxBytes + 1 - data.count
        guard let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { return data }
        data.append(chunk)
    }
    throw AppBindError("INVALID_REQUEST", "Request exceeds 1MiB.")
}

if CommandLine.arguments.count > 1 {
    var code: Int32 = 0
    let result: [String: Any]
    do { result = try serviceCLI(Array(CommandLine.arguments.dropFirst())) }
    catch { code = 1; let error = (error as? AppBindError) ?? AppBindError("SERVICE_ERROR", "Service command failed."); result = ["ok": false, "error": ["code": error.code, "message": error.message]] }
    if var bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { bytes.append(10); try? FileHandle.standardOutput.write(contentsOf: bytes) }
    exit(code)
}

var exitCode: Int32 = 0
let response: [String: Any]
do {
    let request = try Request.parse(readRequest())
    response = ["protocolVersion": 1, "ok": true, "data": try handle(request)]
} catch {
    exitCode = 1
    let failure = (error as? AppBindError) ?? AppBindError("INTERNAL_ERROR", "Helper could not complete the diagnostic request.")
    response = ["protocolVersion": 1, "ok": false, "error": ["code": failure.code, "message": failure.message]]
}
do {
    var data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
} catch { exitCode = 1 }
exit(exitCode)
