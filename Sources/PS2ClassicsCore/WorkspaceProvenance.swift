// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Stable identity for a filesystem entry, captured with `lstat` so a
/// replacement between scan and removal can be detected.
public struct FileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let isDirectory: Bool
    public let isRegularFile: Bool
    public let isSymbolicLink: Bool

    public static func of(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { lstat($0, &info) } ?? -1
        }) == 0 else { return nil }
        let mode = info.st_mode & S_IFMT
        return FileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)),
                            inode: UInt64(info.st_ino),
                            isDirectory: mode == S_IFDIR,
                            isRegularFile: mode == S_IFREG,
                            isSymbolicLink: mode == S_IFLNK)
    }
}

/// Durable provenance recorded by whoever creates a workspace. A matching name
/// alone never proves ownership; only a valid manifest plus a released lock does.
public struct WorkspaceManifest: Codable, Equatable, Sendable {
    public static let format = "ps2-classics/workspace"
    public static let version = 1
    public static let kinds = ["build", "image", "partial", "cache"]

    public var format: String
    public var version: Int
    public var kind: String
    public var jobID: String
    public var output: String?
    public var source: String?
    public var profile: String?
    public var disc: Int?
    public var partial: String?
    /// Full job-fingerprint digest; required when kind == "cache" so a cache
    /// directory is bound to the exact inputs it may serve.
    public var cacheFingerprint: String?
    public var createdAt: String
    public var pid: Int?

    public var isValid: Bool {
        format == Self.format && version == Self.version
            && Self.kinds.contains(kind) && UUID(uuidString: jobID) != nil
    }
    public var isValidCache: Bool {
        isValid && kind == "cache" && (cacheFingerprint?.count == 64)
    }

    /// Reads and parses a manifest, returning the manifest and its exact bytes
    /// so a caller holding a lock can prove nothing changed underneath it.
    public static func readValidated(_ url: URL) -> (manifest: WorkspaceManifest, bytes: Data)? {
        guard let data = try? BoundedFile.read(url, maximum: 64 * 1024) else { return nil }
        guard let manifest = try? JSONDecoder().decode(WorkspaceManifest.self, from: data), manifest.isValid else { return nil }
        return (manifest, data)
    }
}

/// Holds an exclusive lock on a validated lock file from acquisition through
/// release. A second writer — in this process or another — cannot hold it at
/// the same time, so cache-writer exclusion and removal critical sections are
/// safe as long as the guard is alive.
public final class OwnedLock {
    public let lockURL: URL
    private var fd: Int32 = -1
    public var isLive: Bool { fd >= 0 }

    /// Opens O_RDWR|O_NOFOLLOW only after lstat proves a regular non-symlink,
    /// then takes LOCK_EX|LOCK_NB. Any failure (missing file, symlink, held
    /// lock) returns nil: the caller must treat that as "not permitted".
    public init?(lockURL: URL) {
        guard let identity = FileIdentity.of(lockURL), identity.isRegularFile, !identity.isSymbolicLink else { return nil }
        let opened = lockURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard opened >= 0, flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            if opened >= 0 { close(opened) }
            return nil
        }
        self.lockURL = lockURL
        self.fd = opened
    }

    /// Creates the lock file (refusing symlinks) and takes LOCK_EX|LOCK_NB.
    /// Used by a cache writer establishing first ownership of its directory.
    public static func creating(at lockURL: URL) -> OwnedLock? {
        if let identity = FileIdentity.of(lockURL) {
            guard identity.isRegularFile, !identity.isSymbolicLink else { return nil }
        }
        let created = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path = path else { return -1 }
            return open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        if created < 0 {
            // Someone else won the creation race; only proceed if it is a
            // genuine lock file we can take exclusively.
            return OwnedLock(lockURL: lockURL)
        }
        guard flock(created, LOCK_EX | LOCK_NB) == 0 else { close(created); return nil }
        return OwnedLock(__taking: created, lockURL: lockURL)
    }
    /// Wraps an already-held exclusive lock fd. Internal: callers must prove
    /// the fd refers to the validated path with an exclusive lock held.
    init(__taking fd: Int32, lockURL: URL) {
        self.lockURL = lockURL
        self.fd = fd
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// Identity of the open file description (immune to path replacement).
    public func fileIdentity() -> FileIdentity? {
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let mode = info.st_mode & S_IFMT
        return FileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)),
                            inode: UInt64(info.st_ino),
                            isDirectory: mode == S_IFDIR,
                            isRegularFile: mode == S_IFREG,
                            isSymbolicLink: mode == S_IFLNK)
    }

    deinit { release() }
}

/// Fail-closed removal shared by workspace cleanup and cache eviction. Every
/// check that can be raced is performed twice: once as a fast filter, then
/// again while holding the exclusive lock, which is retained through the
/// destructive action itself.
public enum OwnedRemoval {
    public enum Failure: LocalizedError {
        case notOwned(String)
        case changed(String)
        case stillActive(String)
        case removalFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notOwned(let name): return "\(name) was not proven to be this app's work and was left untouched. Review it manually."
            case .changed(let name): return "\(name) changed since it was listed. Rescan before removing anything."
            case .stillActive(let name): return "\(name) is still in use by a running process and was left alone."
            case .removalFailed(let name): return "\(name) could not be removed. Remove it manually after checking it."
            }
        }
    }

    /// Removes a proven-owned directory. `acceptManifest` must confirm the
    /// re-read envelope (kind, fingerprint binding, …) while the lock is held.
    public static func removeDirectory(dir: URL,
                                       expectedIdentity: FileIdentity,
                                       parentIdentity: FileIdentity,
                                       manifestURL: URL,
                                       lockURL: URL,
                                       acceptManifest: (WorkspaceManifest) -> Bool,
                                       toTrash: Bool) throws {
        let name = dir.lastPathComponent
        guard let current = FileIdentity.of(dir), current == expectedIdentity,
              current.isDirectory, !current.isSymbolicLink else {
            throw Failure.changed(name)
        }
        guard FileIdentity.of(dir.deletingLastPathComponent()) == parentIdentity else {
            throw Failure.changed(name)
        }
        guard let first = WorkspaceManifest.readValidated(manifestURL), acceptManifest(first.manifest) else {
            throw Failure.notOwned(name)
        }
        guard let held = OwnedLock(lockURL: lockURL) else {
            throw Failure.stillActive(name)
        }
        defer { held.release() }
        guard let again = FileIdentity.of(dir), again == expectedIdentity,
              again.isDirectory, !again.isSymbolicLink else {
            throw Failure.changed(name)
        }
        guard FileIdentity.of(dir.deletingLastPathComponent()) == parentIdentity else {
            throw Failure.changed(name)
        }
        guard let second = WorkspaceManifest.readValidated(manifestURL),
              acceptManifest(second.manifest), second.bytes == first.bytes else {
            throw Failure.changed(name)
        }
        do {
            if toTrash {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: dir, resultingItemURL: &trashed)
            } else {
                try FileManager.default.removeItem(at: dir)
            }
        } catch {
            throw Failure.removalFailed(name)
        }
    }
}

/// Creates a workspace and holds a shared lock for as long as any writer
/// (the app or a helper child) is alive. Cleanup only proceeds when it can take
/// the exclusive lock, so a surviving helper keeps abandonment undecidable.
public final class WorkspaceClaim {
    public let directory: URL
    public let manifestURL: URL
    public let manifestJobID: String
    private var lockFD: Int32 = -1

    public static let lockName = ".ps2-lock"
    public static let manifestName = ".ps2-owner.json"

    public init?(directory: URL, kind: String, jobID: UUID, output: URL? = nil,
                 source: URL? = nil, profile: String? = nil, disc: Int? = nil) {
        self.directory = directory
        self.manifestURL = directory.appendingPathComponent(Self.manifestName)
        self.manifestJobID = jobID.uuidString
        let lockPath = directory.appendingPathComponent(Self.lockName).path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { close(fd); return nil }
        lockFD = fd
        let manifest = WorkspaceManifest(format: WorkspaceManifest.format, version: WorkspaceManifest.version,
                                         kind: kind, jobID: jobID.uuidString,
                                         output: output?.path, source: source?.path,
                                         profile: profile, disc: disc,
                                         createdAt: ISO8601DateFormatter().string(from: Date()),
                                         pid: Int(getpid()))
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            close(fd); lockFD = -1
            try? FileManager.default.removeItem(at: manifestURL)
            return nil
        }
    }

    public func release() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }

    deinit { release() }
}
