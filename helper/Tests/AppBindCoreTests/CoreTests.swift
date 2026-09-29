import Foundation
import XCTest
@testable import AppBindCore

final class CoreTests: XCTestCase {
    func fixture() -> [String: Any] {
        ["schemaVersion": 1, "bindings": [[
            "id": "test", "name": "Test", "enabled": true,
            "application": ["bundleId": "com.example.app"],
            "trigger": ["type": "hotkey", "key": "k", "modifiers": ["option", "control"], "scope": "frontmost-app"],
            "action": ["type": "window-relative-click", "window": "focused", "anchor": "top-right", "offset": ["x": -42, "y": 76], "button": "left", "restoreCursor": true]
        ]]]
    }
    func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    func changed(_ path: [String], _ value: Any) -> [String: Any] {
        func set(_ object: [String: Any], _ path: ArraySlice<String>) -> [String: Any] {
            var result = object
            let key = path.first!
            if path.count == 1 { result[key] = value }
            else { result[key] = set(object[key] as! [String: Any], path.dropFirst()) }
            return result
        }
        var config = fixture()
        let binding = (config["bindings"] as! [[String: Any]])[0]
        config["bindings"] = [set(binding, path[...])]
        return config
    }
    func assertCode(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? AppBindError)?.code, code, file: file, line: line)
        }
    }
    func testValidAndEmptyConfig() throws {
        let parsed = try Config.parse(encoded(fixture()))
        XCTAssertEqual(parsed.bindings.count, 1)
        XCTAssertEqual(parsed.bindings[0].modifiers, ["control", "option"])
        XCTAssertTrue(try Config.parse(Data("{\"schemaVersion\":1,\"bindings\":[]}".utf8)).bindings.isEmpty)
    }
    func testUnknownFieldsAtEveryLevel() throws {
        for path in [["extra"], ["application", "extra"], ["trigger", "extra"], ["action", "extra"], ["action", "offset", "extra"]] {
            assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(changed(path, true))) }
        }
        var root = fixture(); root["extra"] = true
        assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(root)) }
    }
    func testInvalidFields() throws {
        let invalid: [([String], Any)] = [
            (["id"], "Upper"), (["id"], "x\n"), (["id"], String(repeating: "a", count: 65)),
            (["name"], " "), (["name"], " Test"), (["name"], String(repeating: "a", count: 121)),
            (["enabled"], 1), (["application", "bundleId"], "single"), (["application", "bundleId"], "com.a\n"),
            (["application", "bundleId"], "com.é"), (["trigger", "key"], "K"), (["trigger", "key"], "k\n"),
            (["trigger", "modifiers"], []), (["trigger", "modifiers"], ["control", "control"]),
            (["trigger", "modifiers"], ["meta"]), (["trigger", "scope"], "global"),
            (["action", "restoreCursor"], false), (["action", "restoreCursor"], 1),
            (["action", "button"], "right"), (["action", "window"], "any"),
            (["action", "anchor"], "left"), (["action", "offset", "x"], true),
            (["action", "offset", "y"], 100001), (["action", "offset", "x"], NSNull())
        ]
        for (path, value) in invalid { assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(changed(path, value))) } }
        assertCode("INVALID_CONFIG") { _ = try Config.validate(changed(["action", "offset", "x"], Double.infinity)) }
    }
    func testECMAScriptNameTrimParity() throws {
        assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(changed(["name"], "\u{FEFF}Test"))) }
        XCTAssertEqual(try Config.parse(encoded(changed(["name"], "\u{0085}Test"))).bindings[0].name, "\u{0085}Test")
    }
    func testRequiredFields() throws {
        for field in ["id", "name", "enabled", "application", "trigger", "action"] {
            var root = fixture(); var b = (root["bindings"] as! [[String: Any]])[0]; b.removeValue(forKey: field); root["bindings"] = [b]
            assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(root)) }
        }
    }
    func testDuplicatesIncludeDisabledAndNormalizeModifiers() throws {
        var root = fixture(); let first = (root["bindings"] as! [[String: Any]])[0]
        var second = first; second["id"] = "second"; second["enabled"] = false
        var trigger = second["trigger"] as! [String: Any]; trigger["modifiers"] = ["control", "option"]; second["trigger"] = trigger
        root["bindings"] = [first, second]
        assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(root)) }
        second["application"] = ["bundleId": "com.other.app"]
        root["bindings"] = [first, second]; XCTAssertEqual(try Config.parse(encoded(root)).bindings.count, 2)
        second["id"] = "test"; root["bindings"] = [first, second]
        assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(root)) }
    }
    func testVersionsTypesAndSize() throws {
        var root = fixture(); root["schemaVersion"] = 2
        assertCode("UNSUPPORTED_VERSION") { _ = try Config.parse(encoded(root)) }
        root["schemaVersion"] = true
        assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(root)) }
        assertCode("INVALID_CONFIG") { _ = try Config.parse(Data(repeating: 32, count: Config.maxBytes + 1)) }
        assertCode("INVALID_CONFIG") { _ = try Config.parse(Data([0xff])) }
        assertCode("INVALID_CONFIG") { _ = try Config.parse(Data("{} {}".utf8)) }
        root = fixture(); root["bindings"] = Array(repeating: (root["bindings"] as! [Any])[0], count: 1001)
        assertCode("INVALID_CONFIG") { _ = try Config.parse(encoded(root)) }
    }
    func testRequests() throws {
        for command in ["status", "inspect"] {
            XCTAssertNil(try Request.parse(encoded(["protocolVersion": 1, "command": command])).binding)
            assertCode("INVALID_REQUEST") { _ = try Request.parse(encoded(["protocolVersion": 1, "command": command, "config": fixture()])) }
        }
        for command in ["dry-run", "execute"] {
            let request: [String: Any] = ["protocolVersion": 1, "command": command, "config": fixture(), "bindingId": "test"]
            XCTAssertEqual(try Request.parse(encoded(request)).binding?.id, "test")
            var missing = request; missing["bindingId"] = "missing"
            assertCode("BINDING_NOT_FOUND") { _ = try Request.parse(encoded(missing)) }
            missing["config"] = changed(["enabled"], false); missing["bindingId"] = "test"
            assertCode("BINDING_DISABLED") { _ = try Request.parse(encoded(missing)) }
        }
        for text in ["", "[]", "{}", "null", "{}{}", "{\"protocolVersion\":true,\"command\":\"status\"}", "{\"protocolVersion\":1,\"command\":\"status\",\"geometry\":{}}"] {
            assertCode("INVALID_REQUEST") { _ = try Request.parse(Data(text.utf8)) }
        }
        assertCode("UNSUPPORTED_VERSION") { _ = try Request.parse(encoded(["protocolVersion": 2, "command": "status"])) }
        assertCode("INVALID_REQUEST") { _ = try Request.parse(Data(repeating: 32, count: Config.maxBytes + 1)) }
    }
    func testFiveAnchorsAndHalfOpenBounds() throws {
        let window = Rect(x: -200, y: -100, width: 100, height: 80)
        let display = Rect(x: -500, y: -500, width: 1000, height: 1000)
        let cases: [(Anchor, Point, Point)] = [
            (.topLeft, Point(x: 0, y: 0), Point(x: -200, y: -100)),
            (.topRight, Point(x: -1, y: 0), Point(x: -101, y: -100)),
            (.bottomLeft, Point(x: 0, y: -1), Point(x: -200, y: -21)),
            (.bottomRight, Point(x: -1, y: -1), Point(x: -101, y: -21)),
            (.center, Point(x: 0, y: 0), Point(x: -150, y: -60))]
        for (anchor, offset, expected) in cases {
            XCTAssertEqual(try Geometry.target(window: window, anchor: anchor, offset: offset, displays: [display]), expected)
        }
        for anchor in [Anchor.topRight, .bottomLeft, .bottomRight] {
            assertCode("UNSAFE_TARGET") { _ = try Geometry.target(window: window, anchor: anchor, offset: Point(x: 0, y: 0), displays: [display]) }
        }
        XCTAssertFalse(window.contains(Point(x: -100, y: -50)))
        XCTAssertFalse(window.contains(Point(x: -150, y: -20)))
    }
    func testDisplayGapsSpanningAndInvalidGeometry() throws {
        let window = Rect(x: -100, y: 0, width: 300, height: 100)
        let screens = [Rect(x: -200, y: 0, width: 200, height: 200), Rect(x: 100, y: 0, width: 200, height: 200)]
        assertCode("UNSAFE_TARGET") { _ = try Geometry.target(window: window, anchor: .center, offset: Point(x: 0, y: 0), displays: screens) }
        XCTAssertEqual(try Geometry.target(window: window, anchor: .topLeft, offset: Point(x: 0, y: 0), displays: screens), Point(x: -100, y: 0))
        for rect in [Rect(x: .nan, y: 0, width: 1, height: 1), Rect(x: 0, y: 0, width: 0, height: 1), Rect(x: 0, y: 0, width: -1, height: 1), Rect(x: 0, y: 0, width: .infinity, height: 1), Rect(x: 100001, y: 0, width: 1, height: 1)] {
            XCTAssertFalse(rect.isValid)
            assertCode("UNSAFE_TARGET") { _ = try Geometry.target(window: rect, anchor: .center, offset: Point(x: 0, y: 0), displays: screens) }
        }
        assertCode("UNSAFE_TARGET") { _ = try Geometry.target(window: window, anchor: .center, offset: Point(x: .nan, y: 0), displays: screens) }
    }
}
