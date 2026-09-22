// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// A workspace or unpublished partial found during a scan. `verifiedOwned`
/// entries carry a valid creation manifest and a released writer lock;
/// `unverified` entries merely resemble app naming and require manual review.
public struct OwnedWorkspace: Identifiable, Sendable {
    public enum Confidence: String, Sendable { case verifiedOwned, unverified }
    public var id: URL { url }
    public let url: URL
    public let kind: String
    public let confidence: Confidence
    public let bytes: UInt64
    public let modified: Date?
    public let detail: String
    public let identity: FileIdentity?
    public let parentIdentity: FileIdentity?
    public var isRemovable: Bool { confidence == .verifiedOwned }
}

public enum WorkspaceCleanupError: LocalizedError {
    case notOwned(String)
    case changed(String)
    case stillActive(String)
    case trashFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notOwned(let name): return "\(name) was not proven to be this app's work and was left untouched. Review it manually."
        case .changed(let name): return "\(name) changed since it was listed. Rescan before removing anything."
        case .stillActive(let name): return "\(name) is still in use by a running process and was left alone."
        case .trashFailed(let name): return "\(name) could not be moved to Trash. Remove it manually after checking it."
        }
    }
    static func fromRemoval(_ failure: OwnedRemoval.Failure, name: String) -> WorkspaceCleanupError {
        switch failure {
        case .notOwned: return .notOwned(name)
        case .changed: return .changed(name)
        case .stillActive: return .stillActive(name)
        case .removalFailed: return .trashFailed(name)
        }
    }
}

public enum WorkspaceCleanup {
    public static let manifestName = WorkspaceClaim.manifestName
    public static let lockName = WorkspaceClaim.lockName
    public static let partialManifestPrefix = ".ps2-partial-"
    private static let partialSuffix = #"^(.+)\.partial\.([A-Za-z0-9]{6})$"#
    private static let buildDir = #"^\.ps2-build-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
    private static let imageDir = #"^\.ps2-image-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
    private static let cacheDir = #"^\.ps2-cache-[0-9a-f]{32}$"#

    public static func looksLikeWorkspace(_ name: String) -> Bool {
        name.range(of: buildDir, options: .regularExpression) != nil
            || name.range(of: imageDir, options: .regularExpression) != nil
            || name.range(of: cacheDir, options: .regularExpression) != nil
    }
    public static func looksLikePartial(_ name: String) -> Bool {
        name.range(of: partialSuffix, options: .regularExpression) != nil
    }

    /// Non-recursive, bounded, cancellable scan. `activePaths` is an extra
    /// in-process guard; cross-process safety comes from the shared lock.
    public static func find(in folder: URL,
                            activePaths: Set<String> = [],
                            limit: Int = 2000,
                            isCancelled: () -> Bool = { false }) throws -> [OwnedWorkspace] {
        guard folder.isFileURL else { throw ConversionFailure(message: "Choose a local folder to review.") }
        let parentIdentity = FileIdentity.of(folder)
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants])
        // Pass 1: pair up partial provenance records regardless of directory order.
        var manifestsByPartial = [String: (manifestURL: URL, manifest: WorkspaceManifest)]()
        var entries = [URL]()
        for url in contents {
            if isCancelled() { throw CancellationError() }
            let name = url.lastPathComponent
            if name.hasPrefix(partialManifestPrefix), name.hasSuffix(".json"),
               let manifest = readManifest(url), manifest.kind == "partial",
               let partial = manifest.partial, looksLikePartial(partial),
               partial == URL(fileURLWithPath: partial).lastPathComponent {
                manifestsByPartial[partial] = (url, manifest)
            } else {
                entries.append(url)
            }
        }
        var usedManifests = Set<URL>()
        var results = [OwnedWorkspace]()
        var seen = 0

        // Pass 2: classify each entry.
        for url in entries {
            if isCancelled() { throw CancellationError() }
            seen += 1
            if seen > limit { break }
            let name = url.lastPathComponent
            if name.hasPrefix(partialManifestPrefix) {
                // A record that could not be paired above.
                if let identity = FileIdentity.of(url), !identity.isSymbolicLink, !activePaths.contains(url.standardizedFileURL.path) {
                    results.append(unverified(url, kind: "Unpaired cleanup record", identity: identity, parent: parentIdentity,
                                              modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                                              detail: "Not a valid provenance record. Review manually."))
                }
                continue
            }
            guard !activePaths.contains(url.standardizedFileURL.path) else { continue }
            guard let identity = FileIdentity.of(url), !identity.isSymbolicLink else { continue }

            if looksLikeWorkspace(name) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard identity.isDirectory else {
                    results.append(unverified(url, kind: "Name resembles a workspace", identity: identity,
                                              parent: parentIdentity, modified: modified,
                                              detail: "Not a directory, or no creation manifest. Left untouched."))
                    continue
                }
                guard let manifest = readManifest(url.appendingPathComponent(manifestName)), manifest.isValid,
                      WorkspaceManifest.kinds.contains(manifest.kind),
                      claimedKindMatches(name: name, manifest: manifest) else {
                    results.append(unverified(url, kind: "Unverified workspace", identity: identity,
                                              parent: parentIdentity, modified: modified,
                                              detail: "No valid creation manifest. This may be from an older version; review it manually."))
                    continue
                }
                if manifest.kind == "cache" {
                    // Retained stage caches are owned by cache retention, not by
                    // interruption review. Never offer them here.
                    continue
                }
                guard lockIsFree(url.appendingPathComponent(lockName)) else { continue }   // still being written
                results.append(OwnedWorkspace(url: url, kind: kindLabel(manifest.kind),
                                              confidence: .verifiedOwned, bytes: (try? directoryBytes(url, isCancelled: isCancelled)) ?? 0,
                                              modified: modified, detail: "Created by job \(manifest.jobID.prefix(8)) with no live writer.",
                                              identity: identity, parentIdentity: parentIdentity))
            } else if looksLikePartial(name) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let pair = manifestsByPartial[name], pair.manifest.partial == name, isRegular(identity) else {
                    results.append(unverified(url, kind: "Unverified partial file", identity: identity,
                                              parent: parentIdentity, modified: modified,
                                              detail: "Unpublished file without a creation manifest. Left untouched."))
                    continue
                }
                usedManifests.insert(pair.manifestURL)
                guard lockIsFree(url) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                results.append(OwnedWorkspace(url: url, kind: "Unpublished partial output", confidence: .verifiedOwned,
                                              bytes: UInt64(size), modified: modified,
                                              detail: "Interrupted write for \(pair.manifest.output.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "an output"), no live writer.",
                                              identity: identity, parentIdentity: parentIdentity))
            }
        }

        // Records whose data file has disappeared.
        for (_, pair) in manifestsByPartial where !usedManifests.contains(pair.manifestURL) {
            if isCancelled() { throw CancellationError() }
            guard let identity = FileIdentity.of(pair.manifestURL), !identity.isSymbolicLink,
                  !activePaths.contains(pair.manifestURL.standardizedFileURL.path) else { continue }
            results.append(unverified(pair.manifestURL, kind: "Orphaned cleanup record", identity: identity,
                                      parent: parentIdentity, modified:
                                        (try? pair.manifestURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                                      detail: "Its data file is gone. Review manually."))
        }
        return results.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Revalidates provenance, identity and liveness, then moves the entry to
    /// Trash so the action is reversible. The exclusive lock is held through
    /// the destructive action. Retained stage caches are never removed here —
    /// cache eviction owns them. Never force-deletes.
    public static func remove(_ candidate: OwnedWorkspace, activePaths: Set<String> = []) throws {
        guard candidate.confidence == .verifiedOwned else { throw WorkspaceCleanupError.notOwned(candidate.url.lastPathComponent) }
        guard !activePaths.contains(candidate.url.standardizedFileURL.path) else { throw WorkspaceCleanupError.stillActive(candidate.url.lastPathComponent) }
        guard let identity = candidate.identity, let parent = candidate.parentIdentity else {
            throw WorkspaceCleanupError.notOwned(candidate.url.lastPathComponent)
        }
        let name = candidate.url.lastPathComponent
        if looksLikeWorkspace(name) {
            guard let manifest = readManifest(candidate.url.appendingPathComponent(manifestName)),
                  manifest.kind != "cache", claimedKindMatches(name: name, manifest: manifest) else {
                throw WorkspaceCleanupError.notOwned(name)
            }
            let kind = manifest.kind
            do {
                try OwnedRemoval.removeDirectory(dir: candidate.url, expectedIdentity: identity,
                                                 parentIdentity: parent,
                                                 manifestURL: candidate.url.appendingPathComponent(manifestName),
                                                 lockURL: candidate.url.appendingPathComponent(lockName),
                                                 acceptManifest: { $0.kind == kind && claimedKindMatches(name: name, manifest: $0) },
                                                 toTrash: true)
            } catch let failure as OwnedRemoval.Failure {
                throw WorkspaceCleanupError.fromRemoval(failure, name: name)
            }
            return
        }
        if looksLikePartial(name) {
            guard let suffix = partialSuffixOf(name) else { throw WorkspaceCleanupError.notOwned(name) }
            let record = candidate.url.deletingLastPathComponent()
                .appendingPathComponent("\(partialManifestPrefix)\(suffix).json")
            guard let manifest = readManifest(record), manifest.kind == "partial",
                  manifest.partial == name, manifest.isValid else {
                throw WorkspaceCleanupError.changed(name)
            }
            guard let current = FileIdentity.of(candidate.url), current == identity,
                  current.isRegularFile, !current.isSymbolicLink else {
                throw WorkspaceCleanupError.changed(name)
            }
            guard FileIdentity.of(candidate.url.deletingLastPathComponent()) == parent else {
                throw WorkspaceCleanupError.changed(name)
            }
            guard let held = candidate.url.withUnsafeFileSystemRepresentation({ path -> OwnedLock? in
                guard let path = path else { return nil }
                let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    if fd >= 0 { close(fd) }
                    return nil
                }
                return OwnedLock(__taking: fd, lockURL: candidate.url)
            }) else {
                throw WorkspaceCleanupError.stillActive(name)
            }
            defer { held.release() }
            guard let again = held.fileIdentity(), again == identity, again.isRegularFile else {
                throw WorkspaceCleanupError.changed(name)
            }
            guard let manifest2 = readManifest(record), manifest2.kind == "partial",
                  manifest2.partial == name, manifest2.isValid else {
                throw WorkspaceCleanupError.changed(name)
            }
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: candidate.url, resultingItemURL: &trashed)
                if let companionIdentity = FileIdentity.of(record), !companionIdentity.isSymbolicLink,
                   FileIdentity.of(record.deletingLastPathComponent()) == parent {
                    try? FileManager.default.trashItem(at: record, resultingItemURL: nil)
                }
            } catch {
                throw WorkspaceCleanupError.trashFailed(name)
            }
            return
        }
        throw WorkspaceCleanupError.notOwned(name)
    }

    // MARK: - Helpers

    private static func partialSuffixOf(_ name: String) -> String? {
        guard let range = name.range(of: partialSuffix, options: .regularExpression) else { return nil }
        let match = String(name[range])
        return match.components(separatedBy: ".partial.").last
    }

    private static func isRegular(_ identity: FileIdentity) -> Bool { identity.isRegularFile }

    private static func claimedKindMatches(name: String, manifest: WorkspaceManifest) -> Bool {
        (manifest.kind == "build" && name.range(of: buildDir, options: .regularExpression) != nil)
            || (manifest.kind == "image" && name.range(of: imageDir, options: .regularExpression) != nil)
            || (manifest.kind == "cache" && name.range(of: cacheDir, options: .regularExpression) != nil
                && (manifest.cacheFingerprint ?? "").hasPrefix(String(name.dropFirst(StageCache.prefix.count))))
    }

    private static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "build": return "Interrupted package workspace"
        case "image": return "Interrupted image workspace"
        case "cache": return "Verified stage cache"
        default: return kind
        }
    }

    private static func unverified(_ url: URL, kind: String, identity: FileIdentity, parent: FileIdentity?,
                                   modified: Date?, detail: String) -> OwnedWorkspace {
        OwnedWorkspace(url: url, kind: kind, confidence: .unverified, bytes: 0, modified: modified,
                       detail: detail, identity: identity, parentIdentity: parent)
    }

    private static func readManifest(_ url: URL) -> WorkspaceManifest? {
        guard let data = try? BoundedFile.read(url, maximum: 64 * 1024) else { return nil }
        guard let manifest = try? JSONDecoder().decode(WorkspaceManifest.self, from: data) else { return nil }
        return manifest.isValid ? manifest : nil
    }

    /// Opens the lock without following symlinks and probes for any live writer.
    private static func lockIsFree(_ url: URL) -> Bool {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return true
        }
        return false
    }

    private static func directoryBytes(_ url: URL, isCancelled: () -> Bool) throws -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var total: UInt64 = 0, entries = 0
        for case let file as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            entries += 1
            if entries > 200_000 { break }
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
        }
        return total
    }
}
