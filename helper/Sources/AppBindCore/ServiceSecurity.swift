import Foundation
import Darwin
import CryptoKit

public final class ServiceDirectory {
    public let path: String
    public let fd: Int32
    public init(path: String, create: Bool) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw AppBindError("UNSAFE_DIRECTORY", "An absolute, non-traversing support directory is required.") }
        // Walk each component with no-follow: resolving a symlink first would conceal it.
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw AppBindError("UNSAFE_DIRECTORY", "Cannot open root directory.") }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { close(current); throw AppBindError("UNSAFE_DIRECTORY", "Root cannot be a service directory.") }
        for (index, part) in parts.enumerated() {
            let final = index == parts.count - 1
            if final && create { _ = mkdirat(current, part, 0o700) }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw AppBindError(errno == ENOENT ? "DIRECTORY_NOT_FOUND" : "UNSAFE_DIRECTORY", "Directory is missing, inaccessible, or contains a symbolic link.") }
            current = next
            var info = stat()
            guard fstat(current, &info) == 0,
                  info.st_uid == getuid() || (!final && info.st_uid == 0),
                  final ? (info.st_mode & 0o777 == 0o700 && info.st_uid == getuid()) : (info.st_mode & 0o022 == 0) else {
                close(current); throw AppBindError("UNSAFE_DIRECTORY", "Directory ownership or permissions are unsafe; service directory must be owned by you with mode 0700.")
            }
        }
        self.path = path; fd = current
    }
    deinit { close(fd) }
    public func configuration() throws -> (Config, String) {
        let file = openat(fd, "config.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw AppBindError("INVALID_CONFIG", "Cannot securely open config.json.") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o022 == 0, info.st_nlink == 1, info.st_size <= Config.maxBytes else { throw AppBindError("INVALID_CONFIG", "Configuration is not a safe bounded regular file.") }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while bytes.count <= Config.maxBytes {
            let n = Darwin.read(file, &buffer, min(buffer.count, Config.maxBytes + 1 - bytes.count))
            guard n >= 0 else { throw AppBindError("INVALID_CONFIG", "Configuration read failed.") }
            if n == 0 { break }; bytes.append(contentsOf: buffer.prefix(n))
        }
        var after = stat()
        guard fstat(file, &after) == 0, after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw AppBindError("INVALID_CONFIG", "Configuration changed during reading.") }
        return (try Config.parse(bytes), SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    /// Optional decorative asset (currently the notice icon). Purely cosmetic, so every
    /// unsafe shape is reported as absent rather than failing the caller: a missing file,
    /// a symlink, another owner, a hard link, a writable mode, an empty or oversized file,
    /// or a read that does not complete.
    public func optionalAsset(_ name: String, maximum: Int = 524_288) -> Data? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), maximum > 0 else { return nil }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= maximum else { return nil }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while bytes.count < Int(info.st_size) {
            let n = Darwin.read(file, &buffer, min(buffer.count, Int(info.st_size) - bytes.count))
            guard n > 0 else { return nil }
            bytes.append(contentsOf: buffer.prefix(n))
        }
        return bytes
    }
    public func lock() throws -> Int32 {
        let lock = openat(fd, "service.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        var info = stat()
        guard lock >= 0 else { throw AppBindError("SERVICE_LOCKED", "Cannot open service lock.") }
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock); throw AppBindError("SERVICE_LOCKED", "Service lock is unsafe or already held.")
        }
        return lock
    }
}
