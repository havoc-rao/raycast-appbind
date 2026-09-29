import Foundation
import XCTest

final class CLITests: XCTestCase {
    private func invoke(_ data: Data) throws -> (Int32, [String: Any]) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/appbind-helper")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Run swift build before CLI integration tests.")
        }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(response.last, 10)
        XCTAssertEqual(response.filter { $0 == 10 }.count, 1, "Exactly one JSON response line")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(object["protocolVersion"] as? Int, 1)
        XCTAssertNotEqual(object["data"] == nil, object["error"] == nil, "Exactly data or error")
        return (process.terminationStatus, object)
    }
    func testServiceStatusAndStopAbsentWithoutStartingListener() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(".cache/absent-\(UUID().uuidString)").path
        for command in ["service-status", "service-stop"] {
            let process = Process(), output = Pipe()
            process.executableURL = root.appendingPathComponent(".build/debug/appbind-helper")
            process.arguments = [command, "--directory", path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(bytes.filter { $0 == 10 }.count, 1)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(Set(response.keys), ["ok", "data"])
            let data = try XCTUnwrap(response["data"] as? [String: Any])
            XCTAssertEqual(Set(data.keys), ["running", "executionEnabled", "accessibilityTrusted", "inputMonitoringTrusted", "enabledBindings", "configDigest", "lastError", "pid"])
            XCTAssertEqual(data["running"] as? Bool, false)
            XCTAssertEqual(data["executionEnabled"] as? Bool, false)
            XCTAssertTrue(data["pid"] is NSNull)
            XCTAssertTrue(data["configDigest"] is NSNull)
        }
    }
    func testStatusNeverEnablesExecution() throws {
        let (exit, response) = try invoke(Data("{\"protocolVersion\":1,\"command\":\"status\"}".utf8))
        XCTAssertEqual(exit, 0); XCTAssertEqual(response["ok"] as? Bool, true)
        let data = try XCTUnwrap(response["data"] as? [String: Any])
        XCTAssertEqual(data["executionEnabled"] as? Bool, false)
        XCTAssertNotNil(data["accessibilityTrusted"] as? Bool)
        XCTAssertNotNil(data["helperVersion"] as? String)
    }
    func testCLIRejectsMalformedUnknownAndOversizedInput() throws {
        let invalid = [Data(), Data("{}{}".utf8), Data([0xff]), Data("{\"protocolVersion\":1,\"command\":\"status\",\"extra\":true}".utf8), Data(repeating: 32, count: 1_048_577)]
        for input in invalid {
            let (exit, response) = try invoke(input)
            XCTAssertEqual(exit, 1); XCTAssertEqual(response["ok"] as? Bool, false)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "INVALID_REQUEST")
        }
    }
    func testExecutionFailsClosedAfterValidation() throws {
        let request: [String: Any] = ["protocolVersion": 1, "command": "execute", "config": CoreTests().fixture(), "bindingId": "test"]
        let (exit, response) = try invoke(JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(exit, 1)
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "SAFETY_NOT_IMPLEMENTED")
        var invalid = request; invalid["config"] = ["schemaVersion": 1, "bindings": []]
        let (_, failure) = try invoke(JSONSerialization.data(withJSONObject: invalid))
        XCTAssertEqual((failure["error"] as? [String: Any])?["code"] as? String, "BINDING_NOT_FOUND")
    }
    func testCaptureRejectsMalformedWithoutOverlay() throws {
        let malformed: [[String: Any]] = [
            ["protocolVersion": 1, "command": "capture"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app", "anchor": "middle"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "single", "anchor": "center"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app\n", "anchor": "center"],
            ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app", "anchor": "center", "extra": true],
        ]
        for input in malformed {
            let (exit, response) = try invoke(JSONSerialization.data(withJSONObject: input))
            XCTAssertEqual(exit, 1)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "INVALID_REQUEST")
        }
    }
    func testCapturePreconditionsFailClosedBeforeOverlay() throws {
        // A structurally valid capture request must exit 1 without showing an overlay:
        // either the helper lacks AX trust (PERMISSION_DENIED) or the demo app is not
        // running (APP_NOT_RUNNING). Both are fail-closed and return promptly, so the
        // process never blocks on overlay UI in tests.
        let request: [String: Any] = ["protocolVersion": 1, "command": "capture", "bundleId": "com.example.app", "anchor": "top-right"]
        let (exit, response) = try invoke(JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(exit, 1)
        let code = (response["error"] as? [String: Any])?["code"] as? String ?? ""
        XCTAssertTrue(code == "PERMISSION_DENIED" || code == "APP_NOT_RUNNING", "unexpected fail-closed code \(code)")
    }
}
