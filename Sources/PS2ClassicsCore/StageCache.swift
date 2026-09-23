// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

/// Inputs that determine an encrypted disc image. A change in any field makes
/// the cached artifact ineligible, without needing to trust timestamps alone.
public struct DiscStageKey: Codable, Equatable, Sendable {
    // Identity is content-based (source/config hashes) plus stable
    // descriptors. Size and modification time are deliberately EXCLUDED: they
    // are hints, not identity, and including them would defeat reuse whenever
    // a file is merely touched without changing a byte.
    public var index: Int
    public var sourcePath: String
    public var sourceSHA256: String
    public var gameID: String
    public var configSHA256: String?
    /// SHA-256 of the exact parent CHD bytes used, for parent-dependent
    /// images. Nil for standalone images; a change selects a new cache.
    public var parentSHA256: String?
    public var parentPath: String?
    public init(index: Int, sourcePath: String,
                sourceSHA256: String, gameID: String, configSHA256: String?,
                parentSHA256: String? = nil, parentPath: String? = nil) {
        self.index = index; self.sourcePath = sourcePath
        self.sourceSHA256 = sourceSHA256
        self.gameID = gameID; self.configSHA256 = configSHA256
        self.parentSHA256 = parentSHA256; self.parentPath = parentPath
    }
}

/// The exact cryptographic parameters an encrypted cache artifact was built
/// with. Reuse requires every field to match the current job's snapshots —
/// never a second read of the original paths.
public struct StageBinding: Codable, Equatable, Sendable {
    public var disc: Int
    public var profile: String
    public var sourceSHA256: String
    public var configSHA256: String?
    public var keySHA256: String
    public var rapSHA256: String
    public var contentID: String
    public var helperSHA256: String
    public var parentSHA256: String?
    public init(disc: Int, profile: String, sourceSHA256: String, configSHA256: String?,
                keySHA256: String, rapSHA256: String, contentID: String, helperSHA256: String,
                parentSHA256: String? = nil) {
        self.disc = disc; self.profile = profile; self.sourceSHA256 = sourceSHA256
        self.configSHA256 = configSHA256; self.keySHA256 = keySHA256; self.rapSHA256 = rapSHA256
        self.contentID = contentID; self.helperSHA256 = helperSHA256
        self.parentSHA256 = parentSHA256
    }
}

/// Deterministic description of everything that affects a package build.
/// Hashing the canonical encoding yields the cache identity, so any change of
/// source, settings, support files, helper or content ID selects a new cache.
/// All hashes must come from the immutable workspace snapshots, never from a
/// second read of the original paths.
public struct JobFingerprint: Codable, Equatable, Sendable {
    public var appVersion: String
    public var helperSHA256: String
    public var title: String
    public var titleID: String
    public var contentID: String
    public var cropArtwork: Bool
    public var assets: [String: String]
    public var support: [String: String]
    public var discs: [DiscStageKey]

    public init(appVersion: String, helperSHA256: String, title: String, titleID: String,
                contentID: String, cropArtwork: Bool, assets: [String: String],
                support: [String: String], discs: [DiscStageKey]) {
        self.appVersion = appVersion; self.helperSHA256 = helperSHA256
        self.title = title; self.titleID = titleID; self.contentID = contentID
        self.cropArtwork = cropArtwork; self.assets = assets
        self.support = support; self.discs = discs
    }

    public var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .useDefaultKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Exclusive writer ownership of one cache directory. Only one claim — in this
/// process or any other — can exist at a time. All reads and mutations go
/// through a live claim, so a second builder can never share or race a cache.
public final class CacheWriteClaim {
    public let directory: URL
    public let jobID: UUID
    private let held: OwnedLock
    fileprivate var manifest: StageCache.Manifest

    fileprivate init(directory: URL, jobID: UUID, held: OwnedLock, manifest: StageCache.Manifest) {
        self.directory = directory; self.jobID = jobID; self.held = held; self.manifest = manifest
    }

    public var isLive: Bool { held.isLive }
    public func release() { held.release() }
}

/// A bounded, verified cache of encrypted disc images beside the destination.
/// Reused files are re-hashed before use; the full cryptographic binding must
/// match exactly, and the directory carries the same ownership manifest and
/// lock discipline as a workspace. Version 1 cache records are never trusted.
public final class StageCache {
    public static let version = 2
    public static let prefix = ".ps2-cache-"
    public static let manifestName = "manifest.json"
    public static let cacheNamePattern = #"^\.ps2-cache-[0-9a-f]{32}$"#

    public let directory: URL
    public let fingerprint: JobFingerprint

    struct Manifest: Codable {
        var version: Int
        var fingerprint: String
        var createdAt: Date
        var lastUsed: Date
        var entries: [String: Entry]
    }
    struct Entry: Codable, Equatable {
        var sha256: String
        var size: UInt64
        var binding: StageBinding
    }

    private init(directory: URL, fingerprint: JobFingerprint) {
        self.directory = directory; self.fingerprint = fingerprint
    }

    /// Opens the cache slot for `fingerprint` without trusting anything on
    /// disk. A pre-existing directory with a missing, unreadable, mismatched
    /// or legacy manifest, a symlink, or any non-directory makes the location
    /// unusable — the caller must disable caching, never adopt or delete it.
    public static func open(destinationFolder: URL, fingerprint: JobFingerprint) throws -> StageCache {
        let digest = fingerprint.digest
        let directory = destinationFolder.appendingPathComponent(prefix + String(digest.prefix(32)))
        guard directory.lastPathComponent.range(of: cacheNamePattern, options: .regularExpression) != nil else {
            throw ConversionFailure(message: "The stage cache location is not usable.")
        }
        if let identity = FileIdentity.of(directory) {
            guard identity.isDirectory, !identity.isSymbolicLink else {
                throw ConversionFailure(message: "The stage cache location is blocked by an unrelated file. Caching is disabled for this build.")
            }
            guard let envelope = WorkspaceManifest.readValidated(directory.appendingPathComponent(WorkspaceClaim.manifestName)),
                  envelope.manifest.kind == "cache", envelope.manifest.cacheFingerprint == digest else {
                throw ConversionFailure(message: "The stage cache location has no proven ownership record. Caching is disabled for this build.")
            }
        }
        return StageCache(directory: directory, fingerprint: fingerprint)
    }

    /// Takes exclusive writer ownership. Fails when another builder holds the
    /// cache, when provenance is missing, or when the on-disk cache manifest
    /// is absent, legacy or bound to a different fingerprint. Never overwrites
    /// another owner's record.
    public func acquire(jobID: UUID) throws -> CacheWriteClaim {
        let digest = fingerprint.digest
        let fm = FileManager.default
        let existedBefore = fm.fileExists(atPath: directory.path)
        if !existedBefore {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                throw ConversionFailure(message: "The stage cache location could not be created. Caching is disabled for this build.")
            }
        }
        guard let identity = FileIdentity.of(directory), identity.isDirectory, !identity.isSymbolicLink else {
            throw ConversionFailure(message: "The stage cache location changed unexpectedly. Caching is disabled for this build.")
        }
        let envelopeURL = directory.appendingPathComponent(WorkspaceClaim.manifestName)
        let existing = WorkspaceManifest.readValidated(envelopeURL)?.manifest
        if existing?.kind == "cache", existing?.cacheFingerprint == digest {
            // Prior proven owner record: keep it untouched.
        } else if !existedBefore, existing == nil {
            // Directory created by this call: establish ownership.
            let envelope = WorkspaceManifest(format: WorkspaceManifest.format, version: WorkspaceManifest.version,
                                             kind: "cache", jobID: jobID.uuidString, cacheFingerprint: digest,
                                             createdAt: ISO8601DateFormatter().string(from: Date()), pid: Int(getpid()))
            do {
                let data = try JSONEncoder().encode(envelope)
                try data.write(to: envelopeURL, options: [.atomic])
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envelopeURL.path)
            } catch {
                throw ConversionFailure(message: "The stage cache ownership record could not be written. Caching is disabled for this build.")
            }
        } else {
            throw ConversionFailure(message: "The stage cache location has no proven ownership record. Caching is disabled for this build.")
        }
        guard let held = OwnedLock.creating(at: directory.appendingPathComponent(WorkspaceClaim.lockName)) else {
            throw ConversionFailure(message: "The stage cache is in use by another build. Caching is disabled for this build.")
        }
        let authoritative = readAuthoritativeManifest() ?? Manifest(version: Self.version, fingerprint: digest,
                                                                    createdAt: Date(), lastUsed: Date(), entries: [:])
        guard authoritative.version == Self.version, authoritative.fingerprint == digest else {
            held.release()
            throw ConversionFailure(message: "The stage cache record is from an incompatible version and cannot be trusted. Caching is disabled for this build.")
        }
        return CacheWriteClaim(directory: directory, jobID: jobID, held: held, manifest: authoritative)
    }

    private func readAuthoritativeManifest() -> Manifest? {
        let url = directory.appendingPathComponent(Self.manifestName)
        guard let data = try? BoundedFile.read(url, maximum: 4 * 1024 * 1024),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest
    }

    private func requireLive(_ claim: CacheWriteClaim) throws {
        guard claim.isLive, claim.directory.standardizedFileURL == directory.standardizedFileURL else {
            throw ConversionFailure(message: "The stage cache claim is no longer live. Caching is disabled for this build.")
        }
    }

    /// Durably commits the claim's manifest. Call after every verified stage.
    public func checkpoint(_ claim: CacheWriteClaim) throws {
        try requireLive(claim)
        claim.manifest.lastUsed = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(claim.manifest)
        try data.write(to: directory.appendingPathComponent(Self.manifestName), options: [.atomic])
    }

    /// Returns a verified cached file only when the full cryptographic binding
    /// matches and the bytes on disk re-hash to the recorded digest.
    public func reusableImage(_ name: String, binding: StageBinding, claim: CacheWriteClaim,
                              isCancelled: () -> Bool) -> URL? {
        guard (try? requireLive(claim)) != nil else { return nil }
        guard let entry = claim.manifest.entries[name], entry.binding == binding else { return nil }
        let url = directory.appendingPathComponent(name)
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, UInt64(values.fileSize ?? 0) == entry.size,
              FileIdentity.of(url)?.isSymbolicLink == false else { return nil }
        guard let actual = try? FileDigest.sha256(url, cancelled: { if isCancelled() { throw CancellationError() } }),
              actual == entry.sha256 else {
            claim.manifest.entries[name] = nil
            try? checkpoint(claim)
            return nil
        }
        claim.manifest.lastUsed = Date()
        return url
    }

    /// Atomically publishes a verified artifact and commits the manifest, so a
    /// crash can never leave a recorded entry without bytes or bytes without a
    /// record pointing at unverified content.
    @discardableResult
    public func store(_ source: URL, as name: String, binding: StageBinding, claim: CacheWriteClaim, cancelled: () throws -> Void = {}) throws -> String {
        try requireLive(claim)
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.isEmpty else {
            throw ConversionFailure(message: "The stage cache entry name is invalid.")
        }
        let sha = try FileDigest.sha256(source, cancelled: cancelled)
        let target = directory.appendingPathComponent(name)
        let staging = directory.appendingPathComponent(name + ".incoming-" + UUID().uuidString)
        do { try FileManager.default.linkItem(at: source, to: staging) }
        catch { try FileManager.default.copyItem(at: source, to: staging) }
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staging, backupItemName: nil, options: [])
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw ConversionFailure(message: "The verified stage could not be published to the cache.")
        }
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        claim.manifest.entries[name] = Entry(sha256: sha, size: UInt64(size), binding: binding)
        try checkpoint(claim)
        return sha
    }

    // MARK: - Retention (fail-closed, unified with workspace cleanup)

    /// Directories this app may manage as caches: exact name, real directory,
    /// never a symlink.
    public static func caches(in destinationFolder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: destinationFolder, includingPropertiesForKeys: nil,
                                                       options: [.skipsSubdirectoryDescendants])) ?? [])
            .filter {
                $0.lastPathComponent.range(of: cacheNamePattern, options: .regularExpression) != nil
                    && (FileIdentity.of($0)?.isDirectory == true)
                    && (FileIdentity.of($0)?.isSymbolicLink == false)
            }
    }

    public static func size(ofCache url: URL) -> UInt64 {
        guard let identity = FileIdentity.of(url), identity.isDirectory, !identity.isSymbolicLink else { return 0 }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
                total += UInt64(values.fileSize ?? 0)
            }
        }
        return total
    }

    public static func totalSize(in destinationFolder: URL) -> UInt64 {
        caches(in: destinationFolder).reduce(0) { $0 + size(ofCache: $1) }
    }

    /// Removes one proven-owned cache while holding its lock through the
    /// destructive action. Anything unproven — missing/unreadable lock or
    /// manifests, symlinks, legacy records, fingerprint mismatch — throws and
    /// leaves the directory untouched.
    public static func evict(_ url: URL, toTrash: Bool) throws {
        let name = url.lastPathComponent
        guard name.range(of: cacheNamePattern, options: .regularExpression) != nil else {
            throw OwnedRemoval.Failure.notOwned(name)
        }
        guard let identity = FileIdentity.of(url), identity.isDirectory, !identity.isSymbolicLink else {
            throw OwnedRemoval.Failure.changed(name)
        }
        let suffix = String(name.dropFirst(prefix.count))
        let envelopeURL = url.appendingPathComponent(WorkspaceClaim.manifestName)
        guard let envelope = WorkspaceManifest.readValidated(envelopeURL),
              envelope.manifest.kind == "cache",
              let fingerprint = envelope.manifest.cacheFingerprint,
              fingerprint.count == 64, fingerprint.hasPrefix(suffix) else {
            throw OwnedRemoval.Failure.notOwned(name)
        }
        let manifestURL = url.appendingPathComponent(manifestName)
        guard let record = readCacheManifest(manifestURL), record.version == version,
              record.fingerprint == fingerprint else {
            throw OwnedRemoval.Failure.notOwned(name)
        }
        guard let held = OwnedLock(lockURL: url.appendingPathComponent(WorkspaceClaim.lockName)) else {
            throw OwnedRemoval.Failure.stillActive(name)
        }
        defer { held.release() }
        guard let again = FileIdentity.of(url), again == identity else {
            throw OwnedRemoval.Failure.changed(name)
        }
        guard let envelope2 = WorkspaceManifest.readValidated(envelopeURL),
              envelope2.bytes == envelope.bytes,
              let record2 = readCacheManifest(manifestURL),
              record2.fingerprint == fingerprint, record2.version == version else {
            throw OwnedRemoval.Failure.changed(name)
        }
        do {
            if toTrash {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            throw OwnedRemoval.Failure.removalFailed(name)
        }
    }

    private static func readCacheManifest(_ url: URL) -> Manifest? {
        guard let data = try? BoundedFile.read(url, maximum: 4 * 1024 * 1024),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest
    }

    /// Keeps the newest proven caches within `maxBytes` and `maxAge`. Active
    /// (locked) caches and anything unproven are always skipped.
    @discardableResult
    public static func prune(in destinationFolder: URL, maxBytes: UInt64, maxAge: TimeInterval) -> UInt64 {
        struct Candidate { let url: URL; let used: Date; let bytes: UInt64 }
        var candidates = [Candidate]()
        for url in caches(in: destinationFolder) {
            let used: Date
            if let record = readCacheManifest(url.appendingPathComponent(manifestName)),
               record.version == version {
                used = record.lastUsed
            } else {
                continue // legacy or unproven: never an automatic candidate
            }
            candidates.append(Candidate(url: url, used: used, bytes: size(ofCache: url)))
        }
        var removed: UInt64 = 0
        let now = Date()
        var kept = [Candidate]()
        for candidate in candidates.sorted(by: { $0.used > $1.used }) {
            let expired = now.timeIntervalSince(candidate.used) > maxAge
            let overBudget = kept.reduce(0) { $0 + $1.bytes } + candidate.bytes > maxBytes
            if expired || overBudget {
                if (try? evict(candidate.url, toTrash: false)) != nil { removed += candidate.bytes }
            } else { kept.append(candidate) }
        }
        return removed
    }

    /// User-initiated clearing: same ownership proof, reversible via Trash.
    @discardableResult
    public static func clear(in destinationFolder: URL) -> UInt64 {
        var removed: UInt64 = 0
        for url in caches(in: destinationFolder) {
            let bytes = size(ofCache: url)
            if (try? evict(url, toTrash: true)) != nil { removed += bytes }
        }
        return removed
    }
}
