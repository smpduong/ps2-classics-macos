// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class WorkspaceCleanupTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    /// Simulates a helper-created partial: a data file, a sibling provenance
    /// record, and (optionally) a live shared lock held on the data file.
    @discardableResult
    private func makePartial(in folder: URL, target: String = "/tmp/Game.pkg",
                             suffix: String = "Ab12Cd", holdLock: Bool = false) throws -> (partial: URL, manifest: URL, fd: Int32) {
        let partial = folder.appendingPathComponent("Game.pkg.partial.\(suffix)")
        try Data([1, 2, 3, 4]).write(to: partial)
        let manifest = WorkspaceManifest(format: WorkspaceManifest.format, version: 1, kind: "partial",
                                         jobID: UUID().uuidString, output: target, source: nil,
                                         profile: nil, disc: nil, partial: partial.lastPathComponent,
                                         cacheFingerprint: nil,
                                         createdAt: "2026-09-21T00:00:00Z", pid: Int(getpid()))
        let manifestURL = folder.appendingPathComponent("\(WorkspaceCleanup.partialManifestPrefix)\(suffix).json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        var fd: Int32 = -1
        if holdLock {
            fd = partial.withUnsafeFileSystemRepresentation { open($0!, O_RDWR | O_CLOEXEC) }
            XCTAssertEqual(flock(fd, LOCK_SH | LOCK_NB), 0)
        }
        return (partial, manifestURL, fd)
    }

    func testUnrelatedNamesAreNeverRemovable() throws {
        try temporary { folder in
            // Exactly the review's reproducers plus other decoys.
            try Data([9]).write(to: folder.appendingPathComponent("vacation.partial.backup"))
            let zed = folder.appendingPathComponent(".ps2-build-\(String(repeating: "Z", count: 36))")
            try FileManager.default.createDirectory(at: zed, withIntermediateDirectories: false)
            try Data([7]).write(to: folder.appendingPathComponent("Game.pkg"))
            try Data([7]).write(to: folder.appendingPathComponent("notes.txt"))
            let noManifest = folder.appendingPathComponent(".ps2-build-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: noManifest, withIntermediateDirectories: false)
            let symlink = folder.appendingPathComponent(".ps2-image-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: folder.appendingPathComponent("notes.txt"))

            let found = try WorkspaceCleanup.find(in: folder)
            XCTAssertTrue(found.allSatisfy { $0.confidence == .unverified })
            XCTAssertTrue(found.contains { $0.url.lastPathComponent == "vacation.partial.backup" })
            XCTAssertTrue(found.contains { $0.url.lastPathComponent == noManifest.lastPathComponent })
            // A 36-character non-UUID name is not even offered; it is left entirely alone.
            XCTAssertFalse(found.contains { $0.url.lastPathComponent == zed.lastPathComponent })
            XCTAssertFalse(found.contains { $0.url.lastPathComponent == symlink.lastPathComponent })
            XCTAssertFalse(found.contains { $0.url.lastPathComponent == "Game.pkg" || $0.url.lastPathComponent == "notes.txt" })
            for entry in found where entry.confidence == .unverified {
                XCTAssertThrowsError(try WorkspaceCleanup.remove(entry))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: zed.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("vacation.partial.backup").path))
        }
    }

    func testOwnedWorkspaceIsRecognizedAndTrashedOnlyWhenLockFree() throws {
        try temporary { folder in
            let directory = folder.appendingPathComponent(".ps2-build-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("payload.bin"))
            let claim = try XCTUnwrap(WorkspaceClaim(directory: directory, kind: "build", jobID: UUID()))
            // A live writer (here, the same process on a second description) hides it.
            XCTAssertTrue(try WorkspaceCleanup.find(in: folder).isEmpty)
            claim.release()
            let found = try WorkspaceCleanup.find(in: folder)
            XCTAssertEqual(found.count, 1)
            let entry = try XCTUnwrap(found.first)
            XCTAssertEqual(entry.confidence, .verifiedOwned)
            XCTAssertEqual(entry.bytes, 3)
            try WorkspaceCleanup.remove(entry)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testLivePartialWriterIsProtected() throws {
        try temporary { folder in
            let record = try makePartial(in: folder, holdLock: true)
            defer { if record.fd >= 0 { flock(record.fd, LOCK_UN); close(record.fd) } }
            XCTAssertTrue(try WorkspaceCleanup.find(in: folder).filter { $0.confidence == .verifiedOwned }.isEmpty)
            flock(record.fd, LOCK_UN); close(record.fd)
            let found = try WorkspaceCleanup.find(in: folder)
            XCTAssertEqual(found.filter { $0.confidence == .verifiedOwned }.count, 1)
            try WorkspaceCleanup.remove(try XCTUnwrap(found.first { $0.confidence == .verifiedOwned }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.partial.path))
        }
    }

    func testLiveSecondProcessProtectsOwnedWork() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("python3 unavailable for the cross-process lock check")
        }
        try temporary { folder in
            let directory = folder.appendingPathComponent(".ps2-image-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let claim = try XCTUnwrap(WorkspaceClaim(directory: directory, kind: "image", jobID: UUID()))
            claim.release()
            let lockPath = directory.appendingPathComponent(WorkspaceCleanup.lockName).path
            let ready = folder.appendingPathComponent("ready")
            let script = """
            import fcntl, os, sys, time
            fd = os.open(sys.argv[1], os.O_RDONLY)
            fcntl.flock(fd, fcntl.LOCK_SH)
            open(sys.argv[2], 'w').close()
            time.sleep(4)
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", script, lockPath, ready.path]
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) { usleep(50_000) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "child did not acquire the lock")
            XCTAssertTrue(try WorkspaceCleanup.find(in: folder).isEmpty, "a live helper process must protect the workspace")
            process.terminate(); process.waitUntilExit()
            XCTAssertEqual(try WorkspaceCleanup.find(in: folder).filter { $0.confidence == .verifiedOwned }.count, 1)
        }
    }

    func testStaleCandidateReplacementIsRefused() throws {
        try temporary { folder in
            let name = ".ps2-build-\(UUID().uuidString)"
            let directory = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try XCTUnwrap(WorkspaceClaim(directory: directory, kind: "build", jobID: UUID())).release()
            let entry = try XCTUnwrap(try WorkspaceCleanup.find(in: folder).first)
            // Replace the validated entry with a different inode of the same name.
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try XCTUnwrap(WorkspaceClaim(directory: directory, kind: "build", jobID: UUID())).release()
            XCTAssertThrowsError(try WorkspaceCleanup.remove(entry))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testSupportDiagnosticsExplainMismatchesEarly() throws {
        try temporary { folder in
            let cid = "UP0001-SLUS12345_00-0000000000000001"
            try Data(repeating: 1, count: 16).write(to: folder.appendingPathComponent("klic.bin"))
            try Data(repeating: 2, count: 16).write(to: folder.appendingPathComponent("\(cid).rap"))
            try Data([3]).write(to: folder.appendingPathComponent("PS3LOGO.DAT"))
            try Data([4]).write(to: folder.appendingPathComponent("SCEVMC0.VMC"))
            var support = SupportFiles()
            try support.importFolder(folder)
            XCTAssertEqual(support.contentID, cid)
            XCTAssertFalse(support.mixedSelection)
            XCTAssertTrue(support.diagnostics().isEmpty)
            try Data(repeating: 5, count: 16).write(to: folder.appendingPathComponent("UP0001-SLUS99999_00-0000000000000002.rap"))
            support.rap = folder.appendingPathComponent("UP0001-SLUS99999_00-0000000000000002.rap")
            support.sourceFolder = nil
            let warnings = support.diagnostics()
            XCTAssertTrue(warnings.contains { $0.contains("UP0001-SLUS99999_00-0000000000000002") })
            XCTAssertTrue(warnings.contains { $0.contains("Mixed selection") })
            try Data(repeating: 6, count: 17).write(to: folder.appendingPathComponent("big.key"))
            support.key = folder.appendingPathComponent("big.key")
            XCTAssertTrue(support.diagnostics().contains { $0.contains("17 bytes") })
        }
    }

    /// The path-length guard must be reached, not masked by missing support files.
    func testOverlongDestinationPathIsRejectedForTheRightReason() throws {
        try temporary { folder in
            var project = GameProject()
            project.title = "Example"; project.titleID = "SLUS12345"
            let disc = folder.appendingPathComponent("disc.iso")
            try Data([0]).write(to: disc)
            project.discs = [GameDisc(source: disc, gameID: "SLUS12345")]
            for (name, bytes) in [("key", 16), ("rap", 16), ("logo", 4), ("card", 8)] {
                let url = folder.appendingPathComponent(name)
                try Data(repeating: 7, count: bytes).write(to: url)
            }
            project.support.key = folder.appendingPathComponent("key")
            project.support.rap = folder.appendingPathComponent("rap")
            project.support.logo = folder.appendingPathComponent("logo")
            project.support.card = folder.appendingPathComponent("card")
            project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
            project.output = URL(fileURLWithPath: folder.path + "/" + String(repeating: "n", count: 950) + ".pkg")
            XCTAssertThrowsError(try project.validate()) { error in
                XCTAssertTrue(error.localizedDescription.contains("too long"), error.localizedDescription)
            }
        }
    }

    /// Retained stage caches are owned by cache retention, never by the
    /// interruption review: a healthy v2 cache is neither listed nor removable
    /// here, while a legacy cache-shaped directory stays manual-review only.
    func testRetainedCachesAreOutsideInterruptionReview() throws {
        try temporary { folder in
            let key = DiscStageKey(index: 0, sourcePath: "/tmp/disc.iso", sourceSHA256: "aaaa",
                                   gameID: "SLUS12345", configSHA256: nil)
            let fp = JobFingerprint(appVersion: "0.7.0", helperSHA256: "h", title: "T", titleID: "SLUS12345",
                                    contentID: "UP0001-SLUS12345_00-0000000000000001", cropArtwork: false,
                                    assets: [:], support: [:], discs: [key])
            let cache = try StageCache.open(destinationFolder: folder, fingerprint: fp)
            try cache.acquire(jobID: UUID()).release()
            let legacy = folder.appendingPathComponent(".ps2-cache-" + String(repeating: "b", count: 32))
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
            let found = try WorkspaceCleanup.find(in: folder)
            XCTAssertFalse(found.contains { $0.url.lastPathComponent == cache.directory.lastPathComponent }, "retained caches are not interruption candidates")
            XCTAssertTrue(found.contains { $0.url.lastPathComponent == legacy.lastPathComponent && $0.confidence == .unverified })
            let fabricated = OwnedWorkspace(url: cache.directory, kind: "Verified stage cache",
                                            confidence: .verifiedOwned, bytes: 0, modified: nil,
                                            detail: "", identity: FileIdentity.of(cache.directory),
                                            parentIdentity: FileIdentity.of(folder))
            XCTAssertThrowsError(try WorkspaceCleanup.remove(fabricated), "caches are never removed by interruption review")
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.directory.path))
        }
    }
}
