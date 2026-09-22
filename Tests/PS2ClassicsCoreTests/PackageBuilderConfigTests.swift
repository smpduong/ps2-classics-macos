// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

/// Builder-level regressions for selected-CONFIG handling and the reused-stage
/// stability invariant. Failure cases never reach the helper; the success and
/// mutation cases are gated on PS2_TEST_HELPER like the CHD orchestration test.
final class PackageBuilderConfigTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func validISO(named: String = "disc.iso", in folder: URL) throws -> URL {
        var data = Data(repeating: 0, count: 24 * 2048)
        let offset = 16 * 2048
        data[offset] = 1
        data.replaceSubrange((offset + 1)..<(offset + 6), with: Data("CD001".utf8))
        data[offset + 6] = 1
        data[offset + 80] = 24
        data[offset + 87] = 24
        data[offset + 129] = 8
        data[offset + 130] = 8
        let url = folder.appendingPathComponent(named)
        try data.write(to: url)
        return url
    }

    private func supportFiles(in folder: URL) throws {
        try Data(repeating: 1, count: 16).write(to: folder.appendingPathComponent("klic.bin"))
        try Data(repeating: 2, count: 16).write(to: folder.appendingPathComponent("license.rap"))
        try Data([3]).write(to: folder.appendingPathComponent("PS3LOGO.DAT"))
        var card = Data(repeating: 0, count: 8650752)
        card.replaceSubrange(0..<28, with: Data("Sony PS2 Memory Card Format  ".utf8).prefix(28))
        try card.write(to: folder.appendingPathComponent("SCEVMC0.VMC"))
    }

    private func makeProject(in folder: URL, discs: [GameDisc], output: String) throws -> GameProject {
        try supportFiles(in: folder)
        var project = GameProject()
        project.title = "Config Test"; project.titleID = "SLUS12345"
        project.discs = discs
        project.support.key = folder.appendingPathComponent("klic.bin")
        project.support.rap = folder.appendingPathComponent("license.rap")
        project.support.logo = folder.appendingPathComponent("PS3LOGO.DAT")
        project.support.card = folder.appendingPathComponent("SCEVMC0.VMC")
        project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
        project.output = folder.appendingPathComponent(output)
        return project
    }

    private func disc(_ source: URL, config: URL?, configHash: String?) -> GameDisc {
        var disc = GameDisc(source: source, gameID: "SLUS12345")
        disc.config = config; disc.configHash = configHash
        return disc
    }

    private func buildFails(_ project: GameProject, expecting messagePart: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let builder = PackageBuilder()
        do {
            _ = try builder.build(project, helper: URL(fileURLWithPath: "/nonexistent-helper")) { _ in }
            XCTFail("build must fail", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(messagePart),
                          "wrong error: \(error.localizedDescription)", file: file, line: line)
        }
        if let output = project.output {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                           "a failed build must not publish", file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path + ".report.json"),
                           file: file, line: line)
        }
    }

    func testMissingSelectedConfigFails() throws {
        try temporary { folder in
            let iso = try validISO(in: folder)
            let missing = folder.appendingPathComponent("gone.CONFIG")
            let project = try makeProject(in: folder,
                                      discs: [disc(iso, config: missing, configHash: String(repeating: "1", count: 64))],
                                      output: "missing.pkg")
            try buildFails(project, expecting: "could not be read")
        }
    }

    func testOversizedSelectedConfigFails() throws {
        try temporary { folder in
            let iso = try validISO(in: folder)
            let big = folder.appendingPathComponent("big.CONFIG")
            try Data(repeating: 9, count: 1024 * 1024 + 1).write(to: big)
            let project = try makeProject(in: folder,
                                      discs: [disc(iso, config: big, configHash: String(repeating: "2", count: 64))],
                                      output: "oversized.pkg")
            try buildFails(project, expecting: "could not be read")
        }
    }

    func testEmptyAndDirectoryConfigFail() throws {
        try temporary { folder in
            let iso = try validISO(in: folder)
            let empty = folder.appendingPathComponent("empty.CONFIG")
            try Data().write(to: empty)
            let project = try makeProject(in: folder,
                                      discs: [disc(iso, config: empty, configHash: String(repeating: "3", count: 64))],
                                      output: "empty.pkg")
            try buildFails(project, expecting: "could not be read")
            let dir = folder.appendingPathComponent("dir.CONFIG")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let project2 = try makeProject(in: folder,
                                       discs: [disc(iso, config: dir, configHash: String(repeating: "4", count: 64))],
                                       output: "dir.pkg")
            try buildFails(project2, expecting: "could not be read")
        }
    }

    func testStaleSelectedConfigHashFails() throws {
        try temporary { folder in
            let iso = try validISO(in: folder)
            let config = folder.appendingPathComponent("game.CONFIG")
            try Data(repeating: 5, count: 64).write(to: config)
            let project = try makeProject(in: folder,
                                      discs: [disc(iso, config: config, configHash: String(repeating: "9", count: 64))],
                                      output: "stale.pkg")
            try buildFails(project, expecting: "changed since it was selected")
        }
    }

    func testExistingDestinationFailsBeforeBuilding() throws {
        try temporary { folder in
            let iso = try validISO(in: folder)
            let project = try makeProject(in: folder, discs: [disc(iso, config: nil, configHash: nil)], output: "exists.pkg")
            let sentinel = Data([0x5A])
            try sentinel.write(to: folder.appendingPathComponent("exists.pkg"))
            do {
                _ = try PackageBuilder().build(project, helper: URL(fileURLWithPath: "/nonexistent-helper")) { _ in }
                XCTFail("an existing destination must be refused")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("already exists"), error.localizedDescription)
            }
            // The pre-existing file must be untouched, never overwritten.
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("exists.pkg")), sentinel)
        }
    }

    func testMissingDestinationFolderFailsClearly() throws {
        try temporary { folder in
            let iso = try validISO(in: folder)
            let project = try makeProject(in: folder, discs: [disc(iso, config: nil, configHash: nil)], output: "gone/nested.pkg")
            try buildFails(project, expecting: "missing or disconnected")
        }
    }

    func testReadOnlyDestinationFailsBeforeBuilding() throws {
        try temporary { folder in
            let iso = try validISO(in: folder)
            let readOnly = folder.appendingPathComponent("readonly")
            try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
            var project = try makeProject(in: folder, discs: [disc(iso, config: nil, configHash: nil)], output: "readonly/out.pkg")
            project.output = readOnly.appendingPathComponent("out.pkg")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
            try buildFails(project, expecting: "read-only")
        }
    }

    func testMultiDiscMissingConfigFailsWithoutPublishing() throws {
        try temporary { folder in
            let first = try validISO(named: "disc1.iso", in: folder)
            let second = try validISO(named: "disc2.iso", in: folder)
            let missing = folder.appendingPathComponent("gone2.CONFIG")
            let project = try makeProject(in: folder,
                                      discs: [disc(first, config: nil, configHash: nil),
                                              disc(second, config: missing, configHash: String(repeating: "1", count: 64))],
                                      output: "multi.pkg")
            try buildFails(project, expecting: "could not be read")
        }
    }

    /// Deterministic cache-hit mutation regression: the hook mutates the source
    /// synchronously in-flow just before the shared unchanged-source check, so
    /// no timing race is involved.
    func testReusedStageMutationFailsInsteadOfPublishing() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let helperPath = environment["PS2_TEST_HELPER"],
              FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw XCTSkip("set PS2_TEST_HELPER to run the cache-mutation regression")
        }
        let helper = URL(fileURLWithPath: helperPath)
        try temporary { folder in
            let iso = try validISO(in: folder)
            let seed = try makeProject(in: folder, discs: [disc(iso, config: nil, configHash: nil)], output: "seed.pkg")
            let seeder = PackageBuilder()
            let seeded = try seeder.build(seed, helper: helper) { _ in }
            XCTAssertNotNil(seeded.report)
            // Second build reuses the checkpoint, then the hook mutates the
            // source before the shared stability check runs.
            let retry = try makeProject(in: folder, discs: [disc(iso, config: nil, configHash: nil)], output: "mutated.pkg")
            let builder = PackageBuilder()
            builder.testMutationHook = { stage in
                if stage == "checking-original-0" {
                    let file = try! FileHandle(forWritingTo: iso)
                    try! file.seekToEnd(); try! file.write(contentsOf: Data([123])); try! file.close()
                }
            }
            do {
                _ = try builder.build(retry, helper: helper) { _ in }
                XCTFail("a source mutated before the stability check must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("changed during this build"),
                              "wrong error: \(error.localizedDescription)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mutated.pkg").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mutated.pkg.report.json").path))
        }
    }

    /// A valid selected CONFIG still builds end to end and lands in the package.
    func testValidSelectedConfigBuilds() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let helperPath = environment["PS2_TEST_HELPER"],
              FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw XCTSkip("set PS2_TEST_HELPER to run the valid-CONFIG build")
        }
        try temporary { folder in
            let first = try validISO(named: "disc1.iso", in: folder)
            let second = try validISO(named: "disc2.iso", in: folder)
            let config = folder.appendingPathComponent("game.CONFIG")
            try Data(repeating: 7, count: 128).write(to: config)
            let hash = FileDigest.sha256(data: try Data(contentsOf: config))
            let project = try makeProject(in: folder,
                                      discs: [disc(first, config: config, configHash: hash),
                                              disc(second, config: nil, configHash: nil)],
                                      output: "valid.pkg")
            let result = try PackageBuilder().build(project, helper: URL(fileURLWithPath: helperPath)) { _ in }
            XCTAssertNotNil(result.report)
            let report = try JSONSerialization.jsonObject(with: Data(contentsOf: result.report!)) as! [String: Any]
            let discs = report["discs"] as! [[String: Any]]
            XCTAssertEqual(discs[0]["configSHA256"] as? String, hash)
        }
    }

    /// End-to-end recovery contract: a real build snapshots an immutable
    /// attempt, the report carries it, and recovery confirms the published
    /// package only from that durable binding. A changed crop setting — an
    /// output-affecting setting the old path ignored — invalidates it.
    func testAttemptBindingRoundTripsThroughRealBuild() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let helperPath = environment["PS2_TEST_HELPER"],
              FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw XCTSkip("set PS2_TEST_HELPER to run the recovery-contract round trip")
        }
        let helper = URL(fileURLWithPath: helperPath)
        try temporary { folder in
            let iso = try validISO(in: folder)
            var project = try makeProject(in: folder,
                                      discs: [disc(iso, config: nil, configHash: nil)],
                                      output: "recovery.pkg")
            project.cropArtwork = true
            let jobID = UUID()
            var prepared: BuildAttemptIdentity?
            let result = try PackageBuilder().build(project, helper: helper, jobID: jobID,
                                                     onAttemptPrepared: { prepared = $0 }) { _ in }
            let attempt = try XCTUnwrap(prepared, "the builder must snapshot an attempt")
            XCTAssertEqual(attempt.jobID, jobID.uuidString)
            XCTAssertFalse(attempt.buildFingerprint.isEmpty)

            // Persist and reload through the durable queue-owned store.
            let store = folder.appendingPathComponent("attempts/\(jobID.uuidString).json")
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AttemptStore.save(attempt, to: store)
            let loaded = try XCTUnwrap(AttemptStore.load(at: store))

            let record = try XCTUnwrap(result.report.flatMap(ReportReader.readCompletionRecord),
                                       "the report must parse into a completion record")
            XCTAssertEqual(record.attemptID, attempt.attemptID)
            XCTAssertEqual(record.cropArtwork, true)

            let queued = QueuedJobIdentity(jobID: jobID, project: project)
            let verified = try ConversionRunner().verifyPackage(result.output, helper: helper)
            let digest = try FileDigest.sha256(result.output)
            let wrapped = VerifiedPackage(entries: verified.entries, payloadBytes: verified.payloadBytes,
                                          contentID: verified.contentID, titleID: verified.titleID, names: verified.names)

            XCTAssertEqual(
                RecoveryAssessment.assessJob(queued: queued, attempt: loaded, record: record,
                                             actualDigest: digest, verification: .success(wrapped)),
                .confirmedOutput(entries: verified.entries, payloadBytes: verified.payloadBytes))

            // The old path omitted cropArtwork; changing it must never confirm.
            var tampered = record
            tampered.cropArtwork = !(record.cropArtwork ?? false)
            guard case .containerOnly(let reason) = RecoveryAssessment.assessJob(
                queued: queued, attempt: loaded, record: tampered,
                actualDigest: digest, verification: .success(wrapped)) else {
                return XCTFail("a changed output setting must not confirm")
            }
            XCTAssertTrue(reason.contains("artwork fit setting"), reason)

            // Same paths, different source bytes: a distinct attempt is required.
            let sourceKey = DiscStageKey(index: 0, sourcePath: iso.path,
                                         sourceSHA256: String(repeating: "9", count: 64),
                                         gameID: "SLUS12345", configSHA256: nil)
            var swapped = attempt
            swapped.buildFingerprint = "different-fingerprint"
            swapped.discs = [QueuedDiscIdentity(index: 0, gameID: "SLUS12345", source: iso.path,
                                                sourceSHA256: sourceKey.sourceSHA256, configHash: nil)]
            guard case .containerOnly = RecoveryAssessment.assessJob(
                queued: queued, attempt: swapped, record: record,
                actualDigest: digest, verification: .success(wrapped)) else {
                return XCTFail("changed source bytes must not confirm")
            }
        }
    }
}
