import XCTest
import Foundation
import Darwin
@testable import AppBindCore

final class ServiceTests: XCTestCase {
    func testCancellationGateRejectsOldClickAndRestore() {
        let gate = ExecutionGuard(), token = ExecutionGuard().token()
        var events: [String] = []
        XCTAssertTrue(gate.postIfValid(token) { events += ["down", "up"] })
        gate.cancel()
        XCTAssertFalse(gate.postIfValid(token) { events.append("restore") })
        XCTAssertFalse(gate.postIfValid(token) { events += ["down", "up"] })
        XCTAssertEqual(events, ["down", "up"])
        XCTAssertTrue(gate.postIfValid(gate.token()) { events.append("new") })
    }
    func testUnmatchedAndRepeatPassThrough() {
        var state = ServiceKeyState()
        XCTAssertFalse(state.receive(code: 1, down: true, repeatEvent: false, match: nil, enabled: true).consume)
        XCTAssertFalse(state.receive(code: 1, down: false, repeatEvent: false, match: nil, enabled: true).consume)
        XCTAssertFalse(state.receive(code: 1, down: true, repeatEvent: true, match: "a", enabled: true).consume)
    }
    func testConsumedPairSurvivesCancellationAndRevocation() {
        var state = ServiceKeyState()
        XCTAssertEqual(state.receive(code: 1, down: true, repeatEvent: false, match: "a", enabled: true).trigger, "a")
        let token = state.generation
        state.cancel()
        XCTAssertNotEqual(state.generation, token)
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.receive(code: 1, down: true, repeatEvent: true, match: nil, enabled: false).consume)
        XCTAssertTrue(state.receive(code: 1, down: false, repeatEvent: false, match: nil, enabled: false).consume)
        XCTAssertTrue(state.consumed.isEmpty)
    }
    func testBusyRefusesNewTriggerUntilWorkerFinishes() {
        var state = ServiceKeyState()
        _ = state.receive(code: 1, down: true, repeatEvent: false, match: "a", enabled: true)
        state.cancel()
        // Runtime retains separate busy until A completes, independently of cancel.
        XCTAssertFalse(state.receive(code: 2, down: true, repeatEvent: false, match: "b", enabled: false).consume)
        state.finish()
        XCTAssertEqual(state.receive(code: 3, down: true, repeatEvent: false, match: "c", enabled: true).trigger, "c")
    }
    private func temporary(_ body: (String) throws -> Void) throws {
        // Workspace-local rather than /tmp (symlink on macOS). No sockets or event APIs.
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cache/service-test-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: base) }
        try body(base)
    }
    func testSecureConfigurationDigestAndExclusiveLock() throws {
        try temporary { path in
            let bytes = Data("{\"schemaVersion\":1,\"bindings\":[]}".utf8)
            try bytes.write(to: URL(fileURLWithPath: path + "/config.json"))
            let directory = try ServiceDirectory(path: path, create: false)
            let result = try directory.configuration()
            XCTAssertTrue(result.0.bindings.isEmpty)
            XCTAssertEqual(result.1.count, 64)
            let lock = try directory.lock(); defer { close(lock) }
            XCTAssertThrowsError(try directory.lock())
            try (bytes + Data([10])).write(to: URL(fileURLWithPath: path + "/config.json"))
            XCTAssertNotEqual(try directory.configuration().1, result.1)
        }
    }
    func testRejectDirectoryAndConfigSymlinks() throws {
        try temporary { path in
            let real = path + "/real"
            try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(atPath: path + "/linked", withDestinationPath: real)
            XCTAssertThrowsError(try ServiceDirectory(path: path + "/linked", create: false))
            try FileManager.default.createSymbolicLink(atPath: path + "/config.json", withDestinationPath: real)
            XCTAssertThrowsError(try ServiceDirectory(path: path, create: false).configuration())
        }
    }
    func testRejectUnsafeDirectoryModesAndRelativePaths() throws {
        XCTAssertThrowsError(try ServiceDirectory(path: "relative", create: false))
        try temporary { path in
            XCTAssertEqual(chmod(path, 0o755), 0)
            XCTAssertThrowsError(try ServiceDirectory(path: path, create: false))
        }
    }
    func testRejectFIFOAndOversizedConfig() throws {
        try temporary { path in
            XCTAssertEqual(mkfifo(path + "/config.json", 0o600), 0)
            let directory = try ServiceDirectory(path: path, create: false)
            XCTAssertThrowsError(try directory.configuration())
            XCTAssertEqual(unlink(path + "/config.json"), 0)
            try Data(repeating: 32, count: Config.maxBytes + 1).write(to: URL(fileURLWithPath: path + "/config.json"))
            XCTAssertThrowsError(try directory.configuration())
        }
    }
    func testOptionalAssetIgnoresMissingAndUnsafeShapes() throws {
        try temporary { path in
            let directory = try ServiceDirectory(path: path, create: false)
            XCTAssertNil(directory.optionalAsset("notice-icon.png"))
            XCTAssertNil(directory.optionalAsset(""))
            XCTAssertNil(directory.optionalAsset("../config.json"))
            try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path + "/notice-icon.png"))
            XCTAssertEqual(directory.optionalAsset("notice-icon.png")?.count, 3)
            XCTAssertNil(directory.optionalAsset("notice-icon.png", maximum: 2))
            XCTAssertEqual(chmod(path + "/notice-icon.png", 0o666), 0)
            XCTAssertNil(directory.optionalAsset("notice-icon.png"))
            XCTAssertEqual(unlink(path + "/notice-icon.png"), 0)
            try FileManager.default.createSymbolicLink(atPath: path + "/notice-icon.png", withDestinationPath: path + "/config.json")
            XCTAssertNil(directory.optionalAsset("notice-icon.png"))
        }
    }
}
