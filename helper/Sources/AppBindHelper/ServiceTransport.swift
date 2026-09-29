import Foundation
import AppKit
import ApplicationServices
import AppBindCore
import Darwin

private let socketName = "service.sock"
private func serviceFailure(_ message: String) -> AppBindError { AppBindError("SERVICE_IO", message) }
private func address(_ path: String) throws -> sockaddr_un {
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else { throw serviceFailure("Support directory path is too long for a Unix socket.") }
    a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes + Array(repeating: 0, count: $0.count - bytes.count)) }
    return a
}
private func peer(_ fd: Int32) -> Bool { var uid: uid_t = 0; var gid: gid_t = 0; return getpeereid(fd, &uid, &gid) == 0 && uid == getuid() }
private func configure(_ fd: Int32) { var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))); var timeout = timeval(tv_sec: 1, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) }
private func sendAll(_ fd: Int32, _ bytes: Data) throws {
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count { let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset); guard n > 0 else { throw serviceFailure("Socket write failed.") }; offset += n }
    }
}
private func receive(_ fd: Int32, maximum: Int, pumpEvents: Bool = false) throws -> Data {
    var data = Data(); var byte: UInt8 = 0
    // A whole-message deadline, not merely a per-byte timeout.
    let deadline = Date().addingTimeInterval(1)
    while data.count < maximum && Date() < deadline {
        if pumpEvents {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 0) == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.002)); continue }
        }
        let n = Darwin.read(fd, &byte, 1)
        guard n == 1 else { throw serviceFailure("Socket response was incomplete.") }
        if byte == 10 { return data }; data.append(byte)
    }
    throw serviceFailure("Socket message exceeds its deadline or bound.")
}
@MainActor
private func stoppedStatus() -> [String: Any] {
    ["running": false, "executionEnabled": false, "accessibilityTrusted": AXIsProcessTrusted(), "inputMonitoringTrusted": CGPreflightListenEventAccess(), "enabledBindings": 0, "configDigest": NSNull(), "lastError": NSNull(), "pid": NSNull()]
}
private func request(_ directory: ServiceDirectory, _ command: String) throws -> [String: Any]? {
    var info = stat()
    if fstatat(directory.fd, socketName, &info, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno == ENOENT { return nil }; throw serviceFailure("Cannot inspect service socket.")
    }
    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw serviceFailure("Unsafe service socket.") }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw serviceFailure("Cannot create client socket.") }; defer { close(fd) }; configure(fd)
    // Relative AF_UNIX address avoids sun_path limits for Raycast's long supportPath.
    // CWD is changed only synchronously around connect/bind, before executor work.
    let cwd = open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard cwd >= 0, fchdir(directory.fd) == 0 else { if cwd >= 0 { close(cwd) }; throw serviceFailure("Cannot anchor socket to secure directory.") }
    defer { _ = fchdir(cwd); close(cwd) }
    var a = try address(socketName)
    let result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if result != 0 { if errno == ECONNREFUSED || errno == ENOENT { return nil }; throw serviceFailure("Cannot connect to service.") }
    guard peer(fd) else { throw serviceFailure("Service peer UID mismatch.") }
    try sendAll(fd, Data((command + "\n").utf8))
    guard let response = try JSONSerialization.jsonObject(with: receive(fd, maximum: 16384)) as? [String: Any] else { throw serviceFailure("Invalid service response.") }
    return response
}
@MainActor
func serviceCLI(_ args: [String]) throws -> [String: Any] {
    guard args.count == 3, args[1] == "--directory", ["service-start", "service-status", "service-reload", "service-stop", "service-run"].contains(args[0]) else { throw AppBindError("INVALID_ARGUMENTS", "Use service-start|service-status|service-reload|service-stop --directory ABS_SUPPORT_DIR.") }
    let directory: ServiceDirectory
    do { directory = try ServiceDirectory(path: args[2], create: args[0] == "service-start") }
    catch let error as AppBindError where error.code == "DIRECTORY_NOT_FOUND" && ["service-status", "service-stop"].contains(args[0]) { return ["ok": true, "data": stoppedStatus()] }
    if args[0] == "service-run" { try runService(directory); return ["ok": true, "data": stoppedStatus()] }
    let command = String(args[0].dropFirst(8))
    if let result = try request(directory, command == "start" ? "commit" : command) { return result }
    if command == "status" || command == "stop" { return ["ok": true, "data": stoppedStatus()] }
    guard command == "start" else { throw AppBindError("SERVICE_NOT_RUNNING", "Start the service before reloading.") }
    // The child owns a pre-commit startup lease. Failed response delivery stops it;
    // controller loss after delivery cannot be made an atomic IPC transaction.
    // Process.terminate only targets this exact spawned child.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["service-run", "--directory", directory.path]
    child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    let deadline = Date().addingTimeInterval(5)
    do {
        while Date() < deadline && child.isRunning {
            if let result = try request(directory, "commit") { return result }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw serviceFailure("Service failed to acknowledge startup.")
    } catch { if child.isRunning { child.terminate() }; child.waitUntilExit(); throw error }
}
@MainActor
private func runService(_ directory: ServiceDirectory) throws {
    _ = setsid()
    let lock = try directory.lock(); defer { close(lock) }
    // Only lock owner may remove a stale socket. Never unlink arbitrary filesystem objects.
    var old = stat()
    if fstatat(directory.fd, socketName, &old, AT_SYMLINK_NOFOLLOW) == 0 {
        guard old.st_mode & S_IFMT == S_IFSOCK, old.st_uid == getuid() else { throw serviceFailure("Unsafe stale socket.") }
        guard unlinkat(directory.fd, socketName, 0) == 0 else { throw serviceFailure("Cannot clear stale socket.") }
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw serviceFailure("Cannot create server socket.") }; defer { close(fd) }
    // Relative AF_UNIX address avoids sun_path limits for Raycast's long supportPath.
    // CWD is changed only synchronously around connect/bind, before executor work.
    let cwd = open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard cwd >= 0, fchdir(directory.fd) == 0 else { if cwd >= 0 { close(cwd) }; throw serviceFailure("Cannot anchor socket to secure directory.") }
    defer { _ = fchdir(cwd); close(cwd) }
    var a = try address(socketName)
    let previous = umask(0o177)
    let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    umask(previous)
    guard bound == 0 else { throw serviceFailure("Cannot bind service socket.") }
    defer { unlinkat(directory.fd, socketName, 0) }
    guard listen(fd, 8) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw serviceFailure("Cannot listen on service socket.") }
    let runtime = ServiceRuntime(directory: directory)
    var committed = false, stopping = false
    let lease = Date().addingTimeInterval(7)
    while !stopping && (committed || Date() < lease) {
        let client = accept(fd, nil, nil)
        if client >= 0 {
            configure(client)
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            if peer(client) {
                let wasCommitted = committed
                do {
                    let command = String(data: try receive(client, maximum: 32, pumpEvents: true), encoding: .utf8) ?? ""
                    guard ["status", "reload", "stop", "commit"].contains(command) else { throw serviceFailure("Unknown IPC command.") }
                    if command == "commit" && !committed { committed = true; runtime.start() }
                    if command == "reload" { runtime.reload() }
                    if command == "stop" { runtime.stop(); stopping = true }
                    let response: [String: Any] = ["ok": true, "data": stopping || !committed ? stoppedStatus() : runtime.status()]
                    var bytes = try JSONSerialization.data(withJSONObject: response, options: .sortedKeys); bytes.append(10); try sendAll(client, bytes)
                } catch {
                    if !wasCommitted && committed { runtime.stop(); stopping = true }
                }
            }
            close(client)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    runtime.stop()
}
