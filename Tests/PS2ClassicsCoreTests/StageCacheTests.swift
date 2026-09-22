// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class StageCacheTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func disc(_ index: Int, source: String = "aaaa", config: String? = nil) -> DiscStageKey {
        DiscStageKey(index: index, sourcePath: "/tmp/disc-\(index).iso", sourceSHA256: source,
                     gameID: "SLUS12345", configSHA256: config)
    }

    private func binding(_ index: Int = 0, profile: String = "ISO.BIN.ENC", source: String = "aaaa",
                         config: String? = nil, key: String = "k", contentID: String = "UP0001-SLUS12345_00-0000000000000001",
                         helper: String = "helper-hash") -> StageBinding {
        StageBinding(disc: index, profile: profile, sourceSHA256: source, configSHA256: config,
                     keySHA256: key, rapSHA256: "r", contentID: contentID, helperSHA256: helper)
    }

    private func fingerprint(_ discs: [DiscStageKey], contentID: String = "UP0001-SLUS12345_00-0000000000000001",
                             helper: String = "helper-hash", title: String = "Example") -> JobFingerprint {
        JobFingerprint(appVersion: "0.7.0", helperSHA256: helper, title: title, titleID: "SLUS12345",
                       contentID: contentID, cropArtwork: false,
                       assets: ["icon": "", "background": "", "sound": ""],
                       support: ["key": "k", "rap": "r", "logo": "l", "card": "c"], discs: discs)
    }

    private func openAndAcquire(in folder: URL, fingerprint fp: JobFingerprint) throws -> (StageCache, CacheWriteClaim) {
        let cache = try StageCache.open(destinationFolder: folder, fingerprint: fp)
        return (cache, try cache.acquire(jobID: UUID()))
    }

    func testFingerprintChangesOnEveryInput() {
        let base = fingerprint([disc(0)])
        XCTAssertEqual(base.digest, fingerprint([disc(0)]).digest)
        XCTAssertNotEqual(base.digest, fingerprint([disc(0, source: "bbbb")]).digest)
        XCTAssertNotEqual(base.digest, fingerprint([disc(0, config: "cfg")]).digest)
        XCTAssertNotEqual(base.digest, fingerprint([disc(0)], contentID: "UP0001-SLUS12345_00-0000000000000002").digest)
        XCTAssertNotEqual(base.digest, fingerprint([disc(0)], helper: "other-helper").digest)
        XCTAssertNotEqual(base.digest, fingerprint([disc(0)], title: "Other").digest)
        XCTAssertNotEqual(base.digest, fingerprint([disc(0), disc(1, source: "cccc")]).digest)
    }

    /// Mirrors the review's cache-repro: an unrelated directory that merely
    /// shares the name prefix must survive every retention path, and a cache
    /// slot occupied by junk without provenance is unusable.
    func testUnownedDecoyIsNeverDeleted() throws {
        try temporary { folder in
            let decoy = folder.appendingPathComponent(".ps2-cache-family-photos")
            try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
            try Data("UNRELATED SYNTHETIC SENTINEL".utf8).write(to: decoy.appendingPathComponent("keep.txt"))
            // Occupy this fingerprint's exact slot with junk that has no provenance.
            let fp = fingerprint([disc(0)])
            let blocked = folder.appendingPathComponent(StageCache.prefix + String(fp.digest.prefix(32)))
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
            try Data([1]).write(to: blocked.appendingPathComponent("junk.bin"))
            XCTAssertThrowsError(try StageCache.open(destinationFolder: folder, fingerprint: fp))
            XCTAssertThrowsError(try StageCache.evict(blocked, toTrash: false))
            XCTAssertThrowsError(try StageCache.evict(blocked, toTrash: true))
            _ = StageCache.prune(in: folder, maxBytes: 0, maxAge: 0)
            _ = StageCache.clear(in: folder)
            XCTAssertTrue(FileManager.default.fileExists(atPath: decoy.appendingPathComponent("keep.txt").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("junk.bin").path))
        }
    }

    /// Legacy (version 1) cache records are never trusted for reuse or
    /// eviction; they stay on disk for manual review.
    func testLegacyManifestIsNotTrusted() throws {
        try temporary { folder in
            let fp = fingerprint([disc(0)])
            let digest = fp.digest
            let dir = folder.appendingPathComponent(StageCache.prefix + String(digest.prefix(32)))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let envelope = WorkspaceManifest(format: WorkspaceManifest.format, version: 1, kind: "cache",
                                             jobID: UUID().uuidString, cacheFingerprint: digest,
                                             createdAt: "2026-09-21T00:00:00Z", pid: 1)
            try JSONEncoder().encode(envelope).write(to: dir.appendingPathComponent(WorkspaceClaim.manifestName))
            let legacy = ["version": 1, "fingerprint": digest, "createdAt": 0, "lastUsed": 0, "entries": [:]] as [String: Any]
            try JSONSerialization.data(withJSONObject: legacy).write(to: dir.appendingPathComponent("manifest.json"))
            try Data(repeating: 7, count: 64).write(to: dir.appendingPathComponent("ISO.BIN.ENC"))
            let opened = try StageCache.open(destinationFolder: folder, fingerprint: fp)
            XCTAssertThrowsError(try opened.acquire(jobID: UUID()), "a legacy record must not grant writer ownership")
            XCTAssertThrowsError(try StageCache.evict(dir, toTrash: false))
            XCTAssertThrowsError(try StageCache.evict(dir, toTrash: true))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ISO.BIN.ENC").path))
        }
    }

    func testSecondWriterIsExcluded() throws {
        try temporary { folder in
            let fp = fingerprint([disc(0)])
            let (first, claim1) = try openAndAcquire(in: folder, fingerprint: fp)
            XCTAssertThrowsError(try first.acquire(jobID: UUID()), "two live writer claims must be impossible")
            // A distinct instance sees the same locked slot.
            let second = try StageCache.open(destinationFolder: folder, fingerprint: fp)
            XCTAssertThrowsError(try second.acquire(jobID: UUID()))
            claim1.release()
            let (_, claim2) = try openAndAcquire(in: folder, fingerprint: fp)
            XCTAssertTrue(claim2.isLive)
            claim2.release()
        }
    }

    /// A live writer in another process blocks acquisition; after it exits,
    /// the slot reopens. Mirrors the surviving-helper scenario.
    func testLiveSecondProcessBlocksAcquisition() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("python3 unavailable for the cross-process lock check")
        }
        try temporary { folder in
            let fp = fingerprint([disc(0)])
            let cache = try StageCache.open(destinationFolder: folder, fingerprint: fp)
            let claim = try cache.acquire(jobID: UUID())
            // While our claim is live, a second process cannot take the slot.
            let script = """
            import fcntl, os, sys, time
            fd = os.open(sys.argv[1], os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                sys.exit(42)
            open(sys.argv[2], 'w').close()
            time.sleep(4)
            """
            let ready = folder.appendingPathComponent("ready")
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: python)
            probe.arguments = ["-c", script,
                               cache.directory.appendingPathComponent(WorkspaceClaim.lockName).path,
                               ready.path]
            try probe.run()
            defer { if probe.isRunning { probe.terminate() } }
            // The probe exits 42 immediately when the slot is held; it only
            // creates the ready file after taking the lock.
            let deadline = Date().addingTimeInterval(10)
            while probe.isRunning && Date() < deadline { usleep(50_000) }
            XCTAssertFalse(probe.isRunning, "the probe must exit at once when the slot is held")
            XCTAssertEqual(probe.terminationStatus, 42)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ready.path),
                            "a second process must not take a held cache slot")
            // After releasing, the slot reopens for a new writer.
            claim.release()
            let reopened = try StageCache.open(destinationFolder: folder, fingerprint: fp)
            XCTAssertTrue(try reopened.acquire(jobID: UUID()).isLive)
        }
    }

    func testCheckpointSurvivesReopenAndOrphansDoNot() throws {
        try temporary { folder in
            let fp = fingerprint([disc(0)])
            let key = binding()
            let (cache, claim) = try openAndAcquire(in: folder, fingerprint: fp)
            let source = folder.appendingPathComponent("staged.enc")
            try Data(repeating: 7, count: 4096).write(to: source)
            try cache.store(source, as: "ISO.BIN.ENC", binding: key, claim: claim)
            claim.release()
            // A fresh instance (as after a crash) reuses the checkpointed stage.
            let reopened = try StageCache.open(destinationFolder: folder, fingerprint: fp)
            let claim2 = try reopened.acquire(jobID: UUID())
            XCTAssertNotNil(reopened.reusableImage("ISO.BIN.ENC", binding: key, claim: claim2, isCancelled: { false }))
            // Bytes planted without a manifest record are never reusable.
            try Data(repeating: 9, count: 16).write(to: reopened.directory.appendingPathComponent("ORPHAN.ENC"))
            XCTAssertNil(reopened.reusableImage("ORPHAN.ENC", binding: key, claim: claim2, isCancelled: { false }))
            claim2.release()
        }
    }

    func testReuseRequiresFullBindingAndBytes() throws {
        try temporary { folder in
            let fp = fingerprint([disc(0)])
            let key = binding()
            let (cache, claim) = try openAndAcquire(in: folder, fingerprint: fp)
            let source = folder.appendingPathComponent("staged.enc")
            try Data(repeating: 7, count: 4096).write(to: source)
            try cache.store(source, as: "ISO.BIN.ENC", binding: key, claim: claim)
            claim.release()
            let reopened = try StageCache.open(destinationFolder: folder, fingerprint: fp)
            let claim2 = try reopened.acquire(jobID: UUID())
            defer { claim2.release() }
            for bad in [binding(key: "other-key"), binding(contentID: "UP0001-SLUS12345_00-0000000000000002"),
                        binding(helper: "other-helper"), binding(profile: "ISO.BIN.ENC2"),
                        binding(source: "bbbb"), binding(config: "other")] {
                XCTAssertNil(reopened.reusableImage("ISO.BIN.ENC", binding: bad, claim: claim2, isCancelled: { false }),
                             "binding \(bad) must not reuse")
            }
            // Corrupted cached bytes fail re-verification and are dropped.
            let cached = reopened.directory.appendingPathComponent("ISO.BIN.ENC")
            let handle = try FileHandle(forWritingTo: cached)
            try handle.seek(toOffset: 0); try handle.write(contentsOf: Data([9])); try handle.close()
            XCTAssertNil(reopened.reusableImage("ISO.BIN.ENC", binding: key, claim: claim2, isCancelled: { false }))
        }
    }

    func testReleasedClaimCannotMutate() throws {
        try temporary { folder in
            let fp = fingerprint([disc(0)])
            let (cache, claim) = try openAndAcquire(in: folder, fingerprint: fp)
            claim.release()
            XCTAssertFalse(claim.isLive)
            let source = folder.appendingPathComponent("staged.enc")
            try Data(repeating: 7, count: 32).write(to: source)
            XCTAssertThrowsError(try cache.store(source, as: "ISO.BIN.ENC", binding: binding(), claim: claim))
            XCTAssertThrowsError(try cache.checkpoint(claim))
            XCTAssertNil(cache.reusableImage("ISO.BIN.ENC", binding: binding(), claim: claim, isCancelled: { false }))
        }
    }

    func testSymlinkedCacheLocationIsRejected() throws {
        try temporary { folder in
            let fp = fingerprint([disc(0)])
            let target = folder.appendingPathComponent("real")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let link = folder.appendingPathComponent(StageCache.prefix + String(fp.digest.prefix(32)))
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try StageCache.open(destinationFolder: folder, fingerprint: fp))
        }
    }

    func testPruneSkipsLockedCachesAndEnforcesBound() throws {
        try temporary { folder in
            var held: (StageCache, CacheWriteClaim)?
            for index in 0..<3 {
                let fp = fingerprint([disc(index, source: "s\(index)")])
                let (cache, claim) = try openAndAcquire(in: folder, fingerprint: fp)
                let source = folder.appendingPathComponent("staged-\(index).enc")
                try Data(repeating: UInt8(index), count: 1024 * 1024).write(to: source)
                try cache.store(source, as: "ISO.BIN.ENC",
                                binding: binding(index, source: "s\(index)"), claim: claim)
                if index == 0 { held = (cache, claim) } else { claim.release() }
            }
            XCTAssertEqual(StageCache.caches(in: folder).count, 3)
            // Zero budget evicts everything unlocked, but never the live claim.
            _ = StageCache.prune(in: folder, maxBytes: 0, maxAge: .greatestFiniteMagnitude)
            let remaining = StageCache.caches(in: folder)
            XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(remaining.first?.standardizedFileURL, held?.0.directory.standardizedFileURL)
            held?.1.release()
            _ = StageCache.prune(in: folder, maxBytes: 0, maxAge: .greatestFiniteMagnitude)
            XCTAssertTrue(StageCache.caches(in: folder).isEmpty)
        }
    }

    func testClearMovesOwnedCacheToTrashAndLeavesUnrelatedFiles() throws {
        try temporary { folder in
            let fp = fingerprint([disc(0)])
            let (cache, claim) = try openAndAcquire(in: folder, fingerprint: fp)
            let staged = folder.appendingPathComponent("staged.bin")
            try Data(repeating: 5, count: 32).write(to: staged)
            try cache.store(staged, as: "ISO.BIN.ENC", binding: binding(), claim: claim)
            claim.release()
            let important = folder.appendingPathComponent("Game.pkg")
            try Data([1]).write(to: important)
            _ = StageCache.clear(in: folder)
            XCTAssertTrue(StageCache.caches(in: folder).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: important.path))
        }
    }
}
