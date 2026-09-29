import Foundation
import CoreFoundation

public struct AppBindError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public enum Anchor: String, CaseIterable, Sendable {
    case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left"
    case bottomRight = "bottom-right", center
}
public struct Binding: Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let bundleId: String
    public let key: String
    public let modifiers: [String]
    public let anchor: Anchor
    public let offset: Point
}
public struct Config: Sendable {
    public let bindings: [Binding]
    public static let maxBytes = 1_048_576
    public static func parse(_ data: Data) throws -> Config {
        guard data.count <= maxBytes, String(data: data, encoding: .utf8) != nil else {
            throw AppBindError("INVALID_CONFIG", "Configuration must be UTF-8 and at most 1MiB.")
        }
        do { return try validate(decodeJSON(data)) }
        catch let error as AppBindError { throw error }
        catch { throw AppBindError("INVALID_CONFIG", "Configuration must be a JSON object.") }
    }
    public static func validate(_ value: Any) throws -> Config {
        let v = Validator(code: "INVALID_CONFIG")
        let root = try v.object(value, keys: ["schemaVersion", "bindings"])
        guard try v.number(root["schemaVersion"]) == 1 else { throw AppBindError("UNSUPPORTED_VERSION", "Unsupported configuration schema version.") }
        guard let values = root["bindings"] as? [Any], values.count <= 1000 else { throw v.error("bindings must be an array of at most 1000 entries.") }
        var bindings: [Binding] = [], ids: Set<String> = [], shortcuts: Set<String> = []
        for value in values {
            let b = try v.object(value, keys: ["id", "name", "enabled", "application", "trigger", "action"])
            let id = try v.string(b["id"])
            guard matches(id, "^[a-z0-9][a-z0-9-]{0,63}$"), ids.insert(id).inserted else { throw v.error("Binding IDs must be valid and unique.") }
            let name = try v.string(b["name"])
            let trimScalars: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
            guard let first = name.unicodeScalars.first, let last = name.unicodeScalars.last,
                  !trimScalars.contains(first.value), !trimScalars.contains(last.value), name.utf16.count <= 120 else { throw v.error("Binding name must be trimmed, nonempty, and at most 120 characters.") }
            let enabled = try v.boolean(b["enabled"])
            let app = try v.object(b["application"], keys: ["bundleId"])
            let bundle = try v.string(app["bundleId"])
            guard bundle.utf16.count <= 255, matches(bundle, "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$") else { throw v.error("Invalid bundleId.") }
            let t = try v.object(b["trigger"], keys: ["type", "key", "modifiers", "scope"])
            try v.literal(t["type"], "hotkey"); try v.literal(t["scope"], "frontmost-app")
            let key = try v.string(t["key"])
            guard matches(key, "^[a-z0-9]$") else { throw v.error("key must be one lowercase ASCII letter or digit.") }
            guard let modifiers = t["modifiers"] as? [String], !modifiers.isEmpty,
                  Set(modifiers).count == modifiers.count,
                  Set(modifiers).isSubset(of: ["control", "option", "shift", "command"]) else { throw v.error("Invalid modifiers.") }
            let shortcut = ([bundle, key] + modifiers.sorted()).joined(separator: "|")
            guard shortcuts.insert(shortcut).inserted else { throw v.error("Duplicate application hotkey, including disabled bindings.") }
            let a = try v.object(b["action"], keys: ["type", "window", "anchor", "offset", "button", "restoreCursor"])
            try v.literal(a["type"], "window-relative-click"); try v.literal(a["window"], "focused"); try v.literal(a["button"], "left")
            guard try v.boolean(a["restoreCursor"]) else { throw v.error("restoreCursor must be true.") }
            guard let anchor = Anchor(rawValue: try v.string(a["anchor"])) else { throw v.error("Invalid anchor.") }
            let offset = try v.object(a["offset"], keys: ["x", "y"])
            let point = Point(x: try v.number(offset["x"]), y: try v.number(offset["y"]))
            guard abs(point.x) <= 100_000, abs(point.y) <= 100_000 else { throw v.error("Offsets exceed the supported range.") }
            bindings.append(Binding(id: id, name: name, enabled: enabled, bundleId: bundle, key: key, modifiers: modifiers.sorted(), anchor: anchor, offset: point))
        }
        return Config(bindings: bindings)
    }
}

public enum Command: String, Sendable { case status, inspect, dryRun = "dry-run", capture, execute, recordShortcut = "record-shortcut" }
public struct Request: Sendable {
    public let command: Command
    public let binding: Binding?
    /// Set only for `.capture`: application identity from the form, validated here.
    public let captureBundleId: String?
    public let captureAnchor: Anchor?
    public static func parse(_ data: Data) throws -> Request {
        let v = Validator(code: "INVALID_REQUEST")
        guard data.count <= Config.maxBytes, String(data: data, encoding: .utf8) != nil else { throw v.error("Request must be UTF-8 and at most 1MiB.") }
        let value: Any
        do { value = try decodeJSON(data) }
        catch { throw v.error("Request must be one JSON object.") }
        guard let root = value as? [String: Any], Set(root.keys).isSubset(of: ["protocolVersion", "command", "config", "bindingId", "bundleId", "anchor"]) else { throw v.error("Invalid request object or unknown keys.") }
        guard try v.number(root["protocolVersion"]) == 1 else { throw AppBindError("UNSUPPORTED_VERSION", "Unsupported protocol version.") }
        guard let command = Command(rawValue: try v.string(root["command"])) else { throw v.error("Unknown command.") }
        if command == .status || command == .inspect || command == .recordShortcut {
            _ = try v.object(root, keys: ["protocolVersion", "command"])
            return Request(command: command, binding: nil, captureBundleId: nil, captureAnchor: nil)
        }
        if command == .capture {
            let c = try v.object(root, keys: ["protocolVersion", "command", "bundleId", "anchor"])
            let bundle = try v.string(c["bundleId"])
            guard bundle.utf16.count <= 255, matches(bundle, "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$") else { throw v.error("Invalid bundleId.") }
            guard let anchor = Anchor(rawValue: try v.string(c["anchor"])) else { throw v.error("Invalid anchor.") }
            return Request(command: command, binding: nil, captureBundleId: bundle, captureAnchor: anchor)
        }
        _ = try v.object(root, keys: ["protocolVersion", "command", "config", "bindingId"])
        let id = try v.string(root["bindingId"])
        guard matches(id, "^[a-z0-9][a-z0-9-]{0,63}$") else { throw v.error("Invalid bindingId.") }
        let config = try Config.validate(root["config"] as Any)
        guard let binding = config.bindings.first(where: { $0.id == id }) else { throw AppBindError("BINDING_NOT_FOUND", "Binding does not exist.") }
        guard binding.enabled else { throw AppBindError("BINDING_DISABLED", "Binding is disabled.") }
        return Request(command: command, binding: binding, captureBundleId: nil, captureAnchor: nil)
    }
}

private func matches(_ value: String, _ pattern: String) -> Bool {
    // Require the entire string: ICU's $ can also match before a trailing newline.
    guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
    return range == value.startIndex..<value.endIndex
}
private struct Validator {
    let code: String
    func error(_ message: String) -> AppBindError { AppBindError(code, message) }
    func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else { throw error("Object has missing or unknown fields.") }
        return object
    }
    func string(_ value: Any?) throws -> String {
        guard let s = value as? String else { throw error("Expected a string.") }; return s
    }
    func boolean(_ value: Any?) throws -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw error("Expected a boolean.") }; return n.boolValue
    }
    func number(_ value: Any?) throws -> Double {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw error("Expected a finite number.") }; return n.doubleValue
    }
    func literal(_ value: Any?, _ expected: String) throws {
        guard try string(value) == expected else { throw error("Unsupported enum value.") }
    }
}
