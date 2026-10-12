// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

/// Batch-wide preflight and per-game publication for the standalone
/// PS2 Classic webMAN MOD on HEN workflow. Structural ISO cases run
/// everywhere; the cases that really encrypt are gated on PS2_TEST_HELPER.
final class HENBatchExporterTests: XCTestCase {
    private let contentID = "UP0001-SLUS12345_00-0000000000000001"
    private let badHelperName = "no-such-helper-\(UUID().uuidString)"

    private func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func realHelper() throws -> URL {
        let path = ProcessInfo.processInfo.environment["PS2_TEST_HELPER"] ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("set PS2_TEST_HELPER to run real HEN batch conversion")
        }
        return URL(fileURLWithPath: path)
    }

    /// Minimal ISO-9660 volume descriptor and root directory containing a
    /// SYSTEM.CNF with a PS2 BOOT2 identifier. Accepted by DiscInspector and
    /// by the helper's own descriptor check.
    private func validISO(named name: String, in folder: URL, gameID: String = "SLUS12345") throws -> URL {
        var data = Data(repeating: 0, count: 24 * 2048)
        let descriptor = 16 * 2048
        data[descriptor] = 1
        data.replaceSubrange((descriptor + 1)..<(descriptor + 6), with: Data("CD001".utf8))
        data[descriptor + 6] = 1
        func putBoth(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { data[descriptor + offset + i] = UInt8((value >> (8 * i)) & 0xff) }
            for i in 0..<4 { data[descriptor + offset + 4 + i] = UInt8((value >> (8 * (3 - i))) & 0xff) }
        }
        putBoth(24, at: 80)
        data[descriptor + 128] = 0; data[descriptor + 129] = 8
        data[descriptor + 130] = 8; data[descriptor + 131] = 0
        let rootRecord = descriptor + 156
        data[rootRecord] = 34
        data[rootRecord + 2] = 20
        data[rootRecord + 10] = 0; data[rootRecord + 11] = 8
        data[rootRecord + 25] = 2
        data[rootRecord + 28] = 1; data[rootRecord + 31] = 1
        data[rootRecord + 32] = 1; data[rootRecord + 33] = 0
        let digits = gameID.suffix(5)
        let boot = "BOOT2 = cdrom0:\\" + String(gameID.prefix(4)) + "_"
            + String(digits.prefix(3)) + "." + String(digits.suffix(2)) + ";1\n"
        let cnf = Data(boot.utf8)
        let directory = 20 * 2048
        data[directory] = UInt8(33 + "SYSTEM.CNF;1".utf8.count)
        data[directory + 2] = 21
        data[directory + 10] = UInt8(cnf.count & 0xff); data[directory + 11] = UInt8((cnf.count >> 8) & 0xff)
        data[directory + 25] = 0
        data[directory + 28] = 1; data[directory + 31] = 1
        data[directory + 32] = UInt8("SYSTEM.CNF;1".utf8.count)
        data.replaceSubrange((directory + 33)..<(directory + 33 + "SYSTEM.CNF;1".utf8.count),
                             with: Data("SYSTEM.CNF;1".utf8))
        data.replaceSubrange((21 * 2048)..<(21 * 2048 + cnf.count), with: cnf)
        let terminator = 17 * 2048
        data[terminator] = 255
        data.replaceSubrange((terminator + 1)..<(terminator + 6), with: Data("CD001".utf8))
        data[terminator + 6] = 1
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func key(in folder: URL, bytes: Int = 16, name: String = "klic.bin") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
        return url
    }

    private func plainConfig(_ folder: URL, name: String = "plain.CONFIG", bytes: Int = 4) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x11, count: bytes).write(to: url)
        return url
    }

    private func plan(_ inputs: [HENBatchInput], in root: URL, ftp: Bool = false) throws -> HENBatchPlan {
        try HENBatchExporter.preflight(inputs: inputs, destinationParent: root, ftpLayout: ftp,
                                       keyFile: key(in: root), contentID: contentID)
    }

    private func failure<T>(_ block: () throws -> T,
                            file: StaticString = #filePath, line: UInt = #line) throws -> String {
        do { _ = try block(); XCTFail("expected a rejection", file: file, line: line) }
        catch { return (error as? ConversionFailure)?.message ?? error.localizedDescription }
        return ""
    }

    // MARK: - Batch bounds

    func testBatchAcceptsOneAndFiftyAndRejectsZeroAndFiftyOne() throws {
        try temporary { root in
            let one = try validISO(named: "Single.iso", in: root)
            XCTAssertEqual(try plan([HENBatchInput(source: one)], in: root).items.count, 1)
            let many = try (0..<50).map { index in
                HENBatchInput(source: try validISO(named: "Game-\(index).iso", in: root,
                                                   gameID: "SLES\(10000 + index)"))
            }
            XCTAssertEqual(try plan(many, in: root).items.count, 50)
            let empty = try failure { try self.plan([], in: root) }
            XCTAssertTrue(empty.contains("1–50"), empty)
            let over = try failure { try self.plan(many + [many[0]], in: root) }
            XCTAssertTrue(over.contains("1–50"), over)
        }
    }

    // MARK: - Naming, layout, and source preservation

    /// webMAN MOD recognises the upper-case bracketed title ID that terminates
    /// the name, so the ID must be the last component and the extension exact.
    func testNamesUseTheWebMANBracketFormAndLayoutIsOptional() throws {
        try temporary { root in
            let first = try validISO(named: "A: Game.iso", in: root)
            let second = try validISO(named: "Second.iso", in: root, gameID: "SCUS98765")
            let before = try [FileDigest.sha256(first), FileDigest.sha256(second)]
            let plan = try self.plan([HENBatchInput(source: first), HENBatchInput(source: second)], in: root)
            XCTAssertEqual(plan.readyFolder.lastPathComponent, "Ready for Super Slim")
            XCTAssertEqual(plan.imageFolder, plan.readyFolder)
            XCTAssertEqual(plan.items[0].folderName, "A- Game [SLUS_123.45]")
            XCTAssertEqual(plan.items[0].imageName, "A- Game [SLUS_123.45].BIN.ENC")
            XCTAssertEqual(plan.items[0].configSidecarName, nil)
            XCTAssertEqual(plan.items[1].imageName, "Second [SCUS_987.65].BIN.ENC")
            XCTAssertEqual(plan.consoleDestination, "/dev_hdd0/PS2ISO (copy each game folder's contents in)")
            // The plain layout must state where to copy and that raw ISOs are
            // CFW-only, since this preset emits HEN images.
            XCTAssertTrue(plan.notes.contains { $0.contains("Raw .iso files are CFW-only") }, "\(plan.notes)")
            XCTAssertTrue(plan.notes.contains { $0.contains("PS2 Classics Launcher") }, "\(plan.notes)")

            let nested = try self.plan([HENBatchInput(source: first)], in: root, ftp: true)
            XCTAssertEqual(nested.imageFolder, plan.readyFolder.appendingPathComponent("dev_hdd0/PS2ISO"))
            XCTAssertEqual(nested.consoleDestination, "/dev_hdd0/PS2ISO")
            XCTAssertTrue(nested.notes.contains { $0.contains("does not transfer files") }, "\(nested.notes)")
            XCTAssertTrue(nested.notes.contains { $0.contains("does not store FTP credentials") }, "\(nested.notes)")

            // Preflight inspects and never writes.
            XCTAssertEqual(try [FileDigest.sha256(first), FileDigest.sha256(second)], before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.readyFolder.path))
        }
    }

    func testConfigSidecarIsNamedAfterTheImage() throws {
        try temporary { root in
            let iso = try validISO(named: "Game.iso", in: root)
            let config = try plainConfig(root)
            let plan = try self.plan([HENBatchInput(source: iso, config: config)], in: root)
            XCTAssertEqual(plan.items[0].configSidecarName, "Game [SLUS_123.45].BIN.ENC.CONFIG")
            XCTAssertEqual(plan.items[0].configBytes?.count, 4)
        }
    }

    // MARK: - ISO rejections

    func testRejectsMissingMalformedAndNonRegularISOs() throws {
        try temporary { root in
            let missing = root.appendingPathComponent("missing.iso")
            XCTAssertFalse(try failure({ try self.plan([HENBatchInput(source: missing)], in: root) }).isEmpty)

            let malformed = root.appendingPathComponent("bad.iso")
            try Data(repeating: 0, count: 24 * 2048).write(to: malformed)
            XCTAssertTrue(try failure({ try self.plan([HENBatchInput(source: malformed)], in: root) })
                .contains("SYSTEM.CNF"))

            let empty = root.appendingPathComponent("empty.iso")
            try Data().write(to: empty)
            XCTAssertFalse(try failure({ try self.plan([HENBatchInput(source: empty)], in: root) }).isEmpty)

            // A folder that merely ends in .iso is not a disc image.
            let folder = root.appendingPathComponent("folder.iso")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            XCTAssertTrue(try failure({ try self.plan([HENBatchInput(source: folder)], in: root) })
                .contains("regular ISO file"))

            // A non-ISO extension is refused by this preset.
            let cue = root.appendingPathComponent("Game.cue")
            try Data(repeating: 0, count: 2048).write(to: cue)
            XCTAssertTrue(try failure({ try self.plan([HENBatchInput(source: cue)], in: root) })
                .contains(".iso image"))
        }
    }

    func testRejectsDuplicateSourcesGameIDsAndCollidingFolders() throws {
        try temporary { root in
            let good = try validISO(named: "good.iso", in: root)
            let duplicateSource = try failure {
                try self.plan([HENBatchInput(source: good), HENBatchInput(source: good)], in: root)
            }
            XCTAssertTrue(duplicateSource.contains("appears twice"), duplicateSource)

            // Two different files claiming one title must not both be exported.
            let twinA = try validISO(named: "Game A.iso", in: root)
            let twinB = try validISO(named: "Game B.iso", in: root)
            let duplicateID = try failure {
                try self.plan([HENBatchInput(source: twinA), HENBatchInput(source: twinB)], in: root)
            }
            XCTAssertTrue(duplicateID.contains("same game ID"), duplicateID)

            // Identical stems with identical IDs are the duplicate case above.
            // With distinct IDs the folder name is still distinct, because the
            // bracketed ID terminates it — two same-named files must not
            // silently collapse into one game folder.
            let other = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            let collisionA = try validISO(named: "Twin.iso", in: root)
            let collisionB = try validISO(named: "Twin.iso", in: other, gameID: "SCUS12345")
            let plan = try self.plan([HENBatchInput(source: collisionA), HENBatchInput(source: collisionB)], in: root)
            XCTAssertEqual(plan.items.map { $0.folderName },
                           ["Twin [SLUS_123.45]", "Twin [SCUS_123.45]"])
            XCTAssertEqual(Set(plan.items.map { $0.folder.path }).count, 2)

            // Sanitising a hostile stem must not create a second path level.
            let hostile = try validISO(named: "a:b\\c.iso", in: root, gameID: "SLES55555")
            let safe = try self.plan([HENBatchInput(source: hostile)], in: root)
            XCTAssertEqual(safe.items[0].folderName, "a-b-c [SLES_555.55]")
            XCTAssertEqual(safe.items[0].folder.deletingLastPathComponent().path, safe.imageFolder.path)
        }
    }

    func testRefusesToReplaceAnExistingGameFolder() throws {
        try temporary { root in
            let iso = try validISO(named: "Game.iso", in: root)
            let plan = try self.plan([HENBatchInput(source: iso)], in: root)
            try FileManager.default.createDirectory(at: plan.items[0].folder, withIntermediateDirectories: true)
            let refused = try failure { try self.plan([HENBatchInput(source: iso)], in: root) }
            XCTAssertTrue(refused.contains("already exists"), refused)
            XCTAssertTrue(refused.contains("never replaced"), refused)
        }
    }

    // MARK: - Key and content ID

    func testRejectsWrongKeyTypeAndLength() throws {
        try temporary { root in
            let iso = try validISO(named: "game.iso", in: root)
            for name in ["license.rap", "license.RIF"] {
                let wrong = try key(in: root, name: name)
                let message = try failure {
                    try HENBatchExporter.preflight(inputs: [HENBatchInput(source: iso)], destinationParent: root,
                                                  ftpLayout: false, keyFile: wrong, contentID: contentID)
                }
                XCTAssertTrue(message.contains("RAP/RIF"), message)
            }
            for size in [0, 15, 17, 32] {
                let short = try key(in: root, bytes: size, name: "k\(size).bin")
                XCTAssertFalse(try failure({
                    try HENBatchExporter.preflight(inputs: [HENBatchInput(source: iso)], destinationParent: root,
                                                  ftpLayout: false, keyFile: short, contentID: contentID)
                }).isEmpty, "a \(size)-byte key must be refused")
            }
            let realKey = try key(in: root, name: "real-klic.bin")
            let linkedKey = root.appendingPathComponent("linked-klic.bin")
            try FileManager.default.createSymbolicLink(at: linkedKey, withDestinationURL: realKey)
            let linkedMessage = try failure {
                try HENBatchExporter.preflight(inputs: [HENBatchInput(source: iso)], destinationParent: root,
                                               ftpLayout: false, keyFile: linkedKey, contentID: contentID)
            }
            XCTAssertTrue(linkedMessage.contains("not a link"), linkedMessage)
            for bad in ["bad", "", String(repeating: "A", count: 35), "UP0001-SLUS12345_00-0000000000000001 "] {
                let message = try failure {
                    try HENBatchExporter.preflight(inputs: [HENBatchInput(source: iso)], destinationParent: root,
                                                  ftpLayout: false, keyFile: key(in: root), contentID: bad)
                }
                XCTAssertTrue(message.contains("content ID"), "\(bad): \(message)")
            }
        }
    }

    // MARK: - CONFIG

    func testRejectsMissingEmptyOversizedSealedAndChangedConfig() throws {
        try temporary { root in
            let iso = try validISO(named: "game.iso", in: root)
            let missing = root.appendingPathComponent("missing.CONFIG")
            XCTAssertTrue(try failure({ try self.plan([HENBatchInput(source: iso, config: missing)], in: root) })
                .contains("regular file"))

            let empty = root.appendingPathComponent("empty.CONFIG")
            try Data().write(to: empty)
            let emptyMessage = try failure { try self.plan([HENBatchInput(source: iso, config: empty)], in: root) }
            XCTAssertTrue(emptyMessage.contains("is empty"), emptyMessage)

            let oversized = root.appendingPathComponent("big.CONFIG")
            try Data(repeating: 0, count: HENBatchExporter.maxConfigBytes + 1).write(to: oversized)
            let bigMessage = try failure { try self.plan([HENBatchInput(source: iso, config: oversized)], in: root) }
            XCTAssertTrue(bigMessage.contains("larger than"), bigMessage)

            for header in [Data([80, 83, 50, 0, 1, 2]), Data([78, 80, 68, 0, 1, 2])] {
                let sealed = root.appendingPathComponent(UUID().uuidString + ".CONFIG")
                try header.write(to: sealed)
                let message = try failure { try self.plan([HENBatchInput(source: iso, config: sealed)], in: root) }
                XCTAssertTrue(message.contains("unencrypted CONFIG"), message)
            }

            // A CONFIG edited after it was chosen is refused, not re-read.
            let config = try plainConfig(root)
            let stale = try HENBatchExporter.configFingerprint(config)
            try Data(repeating: 0x22, count: 8).write(to: config)
            XCTAssertNotEqual(try HENBatchExporter.configFingerprint(config), stale)
            let changed = try failure {
                try self.plan([HENBatchInput(source: iso, config: config, configSHA256: stale)], in: root)
            }
            XCTAssertTrue(changed.contains("changed after selection"), changed)

            // Exactly at the bound is still accepted.
            let exact = root.appendingPathComponent("exact.CONFIG")
            try Data(repeating: 0x33, count: HENBatchExporter.maxConfigBytes).write(to: exact)
            XCTAssertEqual(try HENBatchExporter.configBytes(exact).count, HENBatchExporter.maxConfigBytes)
        }
    }

    // MARK: - Capacity

    func testCapacityMathSaturatesAndRefusesATightDestination() throws {
        XCTAssertThrowsError(try HENBatchExporter.checkCapacity(requiredBytes: 100, freeBytes: 99))
        XCTAssertNoThrow(try HENBatchExporter.checkCapacity(requiredBytes: 100, freeBytes: 101))
        XCTAssertEqual(try HENBatchExporter.requiredBytes(for: []), HENBatchExporter.workingMarginBytes)
        try temporary { root in
            let iso = try validISO(named: "game.iso", in: root)
            let plan = try self.plan([HENBatchInput(source: iso)], in: root)
            let item = plan.items[0]
            let withConfig = HENPreparedItem(id: item.id, source: item.source, gameID: item.gameID,
                                             sourceBytes: item.sourceBytes, sourceSHA256: item.sourceSHA256,
                                             folder: item.folder,
                                             imageName: item.imageName, config: item.config,
                                             configSHA256: nil, configBytes: Data(repeating: 0, count: 512))
            let expected = HENBatchExporter.workingMarginBytes &+ item.estimatedOutputBytes &+ 512
            XCTAssertEqual(try HENBatchExporter.requiredBytes(for: [withConfig]), expected)
            XCTAssertGreaterThan(plan.requiredBytes, HENBatchExporter.workingMarginBytes)
        }
    }

    /// A destination that cannot hold the whole batch is refused during
    /// preflight, before any conversion. Needs a genuinely small volume, which
    /// the release gate creates and exposes as PS2_TEST_VOLUME. A no-op
    /// rather than a skip when absent, so it never fakes coverage.
    func testInsufficientDestinationIsRefusedBeforeAnyConversion() throws {
        guard let volume = ProcessInfo.processInfo.environment["PS2_TEST_VOLUME"],
              FileManager.default.fileExists(atPath: volume) else { return }
        let destination = URL(fileURLWithPath: volume)
        try temporary { root in
            let free = try DestinationCheck.limits(for: destination).freeBytes
            guard free < 2 * 1024 * 1024 * 1024 else { return } // volume not small enough to prove this
            // A sparse 6 GiB image: the header is real, the rest is a hole, so
            // the required size is enormous while the small volume stays empty.
            let iso = try validISO(named: "Sparse.iso", in: root)
            let handle = try FileHandle(forWritingTo: iso)
            _ = try handle.truncate(atOffset: 6 * 1024 * 1024 * 1024)
            try handle.close()
            XCTAssertEqual(try (try FileManager.default.attributesOfItem(atPath: iso.path)[.size] as? NSNumber)?.uint64Value,
                           6 * 1024 * 1024 * 1024, "the fixture must really be sparse-sized")
            let message = try failure {
                try HENBatchExporter.preflight(inputs: [HENBatchInput(source: iso)],
                                               destinationParent: destination, ftpLayout: false,
                                               keyFile: key(in: root), contentID: contentID)
            }
            XCTAssertTrue(message.contains("free at the destination"), message)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Ready for Super Slim").path))
        }
    }

    // MARK: - Staleness between preflight and export

    func testChangedKeySourceOrConfigSincePreflightIsRefused() throws {
        try temporary { root in
            let iso = try validISO(named: "Game.iso", in: root)
            let config = try plainConfig(root)
            let plan = try self.plan([HENBatchInput(source: iso, config: config)], in: root)
            let keyFile = try key(in: root)

            try Data(repeating: 0x77, count: 16).write(to: keyFile)
            let keyChanged = try failure {
                try HENBatchExporter.export(plan.items[0], plan: plan,
                                            helper: root.appendingPathComponent(badHelperName),
                                            runner: ConversionRunner()) { _ in }
            }
            XCTAssertTrue(keyChanged.contains("klicensee changed"), keyChanged)

            try Data(repeating: 0x5a, count: 16).write(to: keyFile)
            try Data(repeating: 0x99, count: 6).write(to: config)
            let configChanged = try failure {
                try HENBatchExporter.export(plan.items[0], plan: plan,
                                            helper: root.appendingPathComponent(badHelperName),
                                            runner: ConversionRunner()) { _ in }
            }
            XCTAssertTrue(configChanged.contains("CONFIG changed"), configChanged)

            try plainConfig(root)
            // A structural change the re-inspection can see: the declared disc
            // no longer matches what preflight approved.
            let grown = try FileHandle(forWritingTo: iso)
            _ = try grown.truncate(atOffset: 40 * 2048)
            try grown.close()
            let sourceChanged = try failure {
                try HENBatchExporter.export(plan.items[0], plan: plan,
                                            helper: root.appendingPathComponent(badHelperName),
                                            runner: ConversionRunner()) { _ in }
            }
            XCTAssertTrue(sourceChanged.contains("ISO changed"), sourceChanged)
        }
    }

    func testSameSizeISOReplacementWithSameGameIDInvalidatesPreflight() throws {
        try temporary { root in
            let iso = try validISO(named: "Game.iso", in: root)
            let plan = try self.plan([HENBatchInput(source: iso)], in: root)
            let originalSize = try XCTUnwrap((try iso.resourceValues(forKeys: [.fileSizeKey])).fileSize)
            let handle = try FileHandle(forUpdating: iso)
            try handle.seek(toOffset: UInt64(originalSize - 1))
            try handle.write(contentsOf: Data([0x7f]))
            try handle.close()
            XCTAssertNotEqual(try FileDigest.sha256(iso), plan.items[0].sourceSHA256)
            let message = try failure {
                try HENBatchExporter.export(plan.items[0], plan: plan,
                                            helper: root.appendingPathComponent(badHelperName),
                                            runner: ConversionRunner()) { _ in }
            }
            XCTAssertTrue(message.contains("ISO bytes changed since preflight"), message)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].folder.path))
        }
    }

    /// A stand-in for the helper that reports success slowly, so a change made
    /// *while* a job is running is observed at a deterministic point.
    private func slowHelper(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("slow-helper")
        let script = """
        #!/bin/sh
        sleep 1
        echo '{"stage":"complete","locallyVerified":true}'
        exit 0
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The source ISO, key and optional CONFIG are checked after the helper.
    /// Changing any of them mid-conversion must fail that game and publish
    /// nothing, rather than sealing a mismatched pair.
    func testSourceKeyOrConfigChangedDuringConversionFailsThatGame() throws {
        try temporary { root in
            let helper = try slowHelper(in: root)
            for changed in ["source", "key", "config"] {
                let folder = root.appendingPathComponent(changed)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let iso = try validISO(named: "Game.iso", in: folder)
                let keyFile = try key(in: folder)
                let config = try plainConfig(folder)
                let plan = try self.plan([HENBatchInput(source: iso, config: config)], in: folder)
                let before = try FileDigest.sha256(iso)
                let captured = DispatchSemaphore(value: 0)
                let finished = NSLock()
                var result: Result<URL, Error> = .success(folder)
                DispatchQueue.global().async {
                    let outcome = Result { try HENBatchExporter.export(plan.items[0], plan: plan, helper: helper,
                                                                       runner: ConversionRunner()) { _ in } }
                    finished.lock(); result = outcome; finished.unlock()
                    captured.signal()
                }
                // Mutate while the stand-in helper is still working.
                Thread.sleep(forTimeInterval: 0.35)
                if changed == "source" {
                    let handle = try FileHandle(forWritingTo: iso)
                    _ = try handle.truncate(atOffset: 44 * 2048)
                    try handle.close()
                } else if changed == "key" {
                    try Data(repeating: 0x33, count: 16).write(to: keyFile)
                } else {
                    try Data(repeating: 0x44, count: 6).write(to: config)
                }
                captured.wait()
                finished.lock(); let outcome = result; finished.unlock()
                switch outcome {
                case .success(let published):
                    XCTFail("\(changed): a change during conversion must not publish \(published.path)")
                case .failure(let error):
                    let message = (error as? ConversionFailure)?.message ?? error.localizedDescription
                    XCTAssertTrue(message.contains("changed during conversion"), "\(changed): \(message)")
                    XCTAssertTrue(message.contains("no output was published"), "\(changed): \(message)")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].folder.path), changed)
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: plan.imageFolder.path)
                    .filter { $0.hasPrefix(".ps2-hen-") }
                XCTAssertTrue(leftovers.isEmpty, "\(changed): staged folders must not survive: \(leftovers)")
                if changed == "source" { XCTAssertNotEqual(try FileDigest.sha256(iso), before) }
            }
        }
    }

    // MARK: - Cancellation

    func testCancellationPublishesNothingAndPreservesSource() throws {
        try temporary { root in
            let iso = try validISO(named: "game.iso", in: root)
            let sourceHash = try FileDigest.sha256(iso)
            let plan = try self.plan([HENBatchInput(source: iso)], in: root)
            let runner = ConversionRunner()
            runner.cancel()
            let message = try failure {
                try HENBatchExporter.export(plan.items[0], plan: plan,
                                            helper: root.appendingPathComponent(badHelperName),
                                            runner: runner) { _ in }
            }
            XCTAssertTrue(HENBatchExporter.isCancellation(ConversionFailure(message: message)), message)
            XCTAssertFalse(HENBatchExporter.isCancellation(
                ConversionFailure(message: "Cannot inspect /tmp/Cancelled Game.iso")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].folder.path))
            XCTAssertEqual(try FileDigest.sha256(iso), sourceHash)
            // Nothing may be created at all when the job is cancelled up front.
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.readyFolder.path))
        }
    }

    /// Cancel after the helper has started, not merely before export. The
    /// interrupted child must be reported as cancellation and cleaned up.
    func testMidJobCancellationStopsHelperAndRemovesPrivateOutput() throws {
        try temporary { root in
            let iso = try validISO(named: "Cancel.iso", in: root)
            let before = try FileDigest.sha256(iso)
            let plan = try self.plan([HENBatchInput(source: iso)], in: root)
            let helper = root.appendingPathComponent("waiting-helper")
            let script = """
            #!/bin/sh
            touch "$(dirname "$0")/helper-started"
            sleep 5
            exit 0
            """
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let runner = ConversionRunner()
            let finished = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var result: Result<URL, Error>?
            DispatchQueue.global().async {
                let outcome = Result { try HENBatchExporter.export(plan.items[0], plan: plan,
                                                                   helper: helper, runner: runner) { _ in } }
                resultLock.lock(); result = outcome; resultLock.unlock()
                finished.signal()
            }
            let marker = root.appendingPathComponent("helper-started")
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the helper must have started")
            runner.cancel()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            resultLock.lock(); let outcome = result; resultLock.unlock()
            guard let outcome, case .failure(let error) = outcome else {
                XCTFail("a cancelled running helper must not publish")
                return
            }
            XCTAssertTrue(HENBatchExporter.isCancellation(error), "\(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].folder.path))
            XCTAssertEqual(try FileDigest.sha256(iso), before)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: plan.imageFolder.path)
                .filter { $0.hasPrefix(".ps2-hen-") }
            XCTAssertTrue(leftovers.isEmpty, "private staging folders must be removed: \(leftovers)")
        }
    }

    func testPreflightIsCancellable() throws {
        try temporary { root in
            let iso = try validISO(named: "game.iso", in: root)
            let message = try failure {
                try HENBatchExporter.preflight(inputs: [HENBatchInput(source: iso)], destinationParent: root,
                                               ftpLayout: false, keyFile: key(in: root), contentID: contentID,
                                               cancelled: { throw ConversionFailure(message: "Cancelled. No output was published.") })
            }
            XCTAssertTrue(message.contains("Cancelled"), message)
        }
    }

    // MARK: - Real conversion

    /// A failed job must leave no staged folder and nothing that looks like a
    /// finished game. The helper is missing, which fails after the private
    /// staging folder already exists.
    func testFailedExportLeavesNoStagedFolderAndNothingComplete() throws {
        try temporary { root in
            let iso = try validISO(named: "Game.iso", in: root)
            let sourceHash = try FileDigest.sha256(iso)
            let plan = try self.plan([HENBatchInput(source: iso)], in: root)
            let message = try failure {
                try HENBatchExporter.export(plan.items[0], plan: plan,
                                            helper: root.appendingPathComponent(badHelperName),
                                            runner: ConversionRunner()) { _ in }
            }
            XCTAssertTrue(message.contains("missing"), message)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].folder.path))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: plan.imageFolder.path)
                .filter { $0.hasPrefix(".ps2-hen-") }
            XCTAssertTrue(leftovers.isEmpty, "private staging folders must be removed: \(leftovers)")
            XCTAssertEqual(try FileDigest.sha256(iso), sourceHash)
        }
    }

    /// End-to-end: publishes one verified game folder holding the image and
    /// its CONFIG sidecar, leaves the source byte-identical, and refuses a
    /// second run over the same ISO.
    func testRealExportPublishesVerifiedFolderAndRefusesRerun() throws {
        let helper = try realHelper()
        try temporary { root in
            let source = root.appendingPathComponent("sources")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let iso = try validISO(named: "My Game.iso", in: source)
            let config = try plainConfig(source, name: "My Game.CONFIG", bytes: 32)
            let before = try FileDigest.sha256(iso)
            let plan = try HENBatchExporter.preflight(
                inputs: [HENBatchInput(source: iso, config: config, configSHA256: try HENBatchExporter.configFingerprint(config))],
                destinationParent: destination, ftpLayout: false, keyFile: key(in: root), contentID: contentID)
            let folder = try HENBatchExporter.export(plan.items[0], plan: plan, helper: helper,
                                                     runner: ConversionRunner()) { _ in }
            let image = folder.appendingPathComponent(plan.items[0].imageName)
            let sidecar = folder.appendingPathComponent(plan.items[0].imageName + ".CONFIG")
            XCTAssertEqual(folder.lastPathComponent, "My Game [SLUS_123.45]")
            XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
            XCTAssertEqual(try Data(contentsOf: sidecar).count, 32)
            // The image must be the verified base profile, not a numbered one.
            let detection = try ConversionRunner().inspectEncrypted(image, helper: helper)
            XCTAssertEqual(detection.logicalName, "ISO.BIN.ENC")
            XCTAssertEqual(detection.complete, true)
            XCTAssertEqual(try FileDigest.sha256(iso), before, "the source ISO must be untouched")
            let staged = try FileManager.default.contentsOfDirectory(atPath: plan.imageFolder.path)
            XCTAssertFalse(staged.contains { $0.hasPrefix(".ps2-hen-") })

            // Retry after success is refused rather than replacing the work.
            let rerun = try failure {
                try HENBatchExporter.preflight(inputs: [HENBatchInput(source: iso)], destinationParent: destination,
                                               ftpLayout: false, keyFile: key(in: root), contentID: contentID)
            }
            XCTAssertTrue(rerun.contains("already exists"), rerun)
        }
    }

    /// A failed attempt is recoverable: the same preflight and export succeed
    /// once the cause is gone, and the retry publishes exactly one folder.
    func testRetryAfterFailureSucceeds() throws {
        let helper = try realHelper()
        try temporary { root in
            let iso = try validISO(named: "Retry.iso", in: root)
            let plan = try self.plan([HENBatchInput(source: iso)], in: root)
            let first = try failure {
                try HENBatchExporter.export(plan.items[0], plan: plan,
                                            helper: root.appendingPathComponent(badHelperName),
                                            runner: ConversionRunner()) { _ in }
            }
            XCTAssertTrue(first.contains("missing"), first)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].folder.path))

            let folder = try HENBatchExporter.export(plan.items[0], plan: plan, helper: helper,
                                                     runner: ConversionRunner()) { _ in }
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("Retry [SLUS_123.45].BIN.ENC").path))
            let games = try FileManager.default.contentsOfDirectory(atPath: plan.imageFolder.path)
                .filter { $0 == "Retry [SLUS_123.45]" }
            XCTAssertEqual(games.count, 1)
        }
    }

    /// Two of the user's discs of one game, converted as two independent
    /// standalone images. This proves the local per-image path only.
    func testRealBatchConvertsEachDiscIndependently() throws {
        let helper = try realHelper()
        try temporary { root in
            let source = root.appendingPathComponent("sources")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let one = try validISO(named: "Xenosaga II (Disc 1).iso", in: source, gameID: "SLUS20892")
            let two = try validISO(named: "Xenosaga II (Disc 2).iso", in: source, gameID: "SLUS21133")
            let before = try [FileDigest.sha256(one), FileDigest.sha256(two)]
            let plan = try HENBatchExporter.preflight(
                inputs: [HENBatchInput(source: one), HENBatchInput(source: two)],
                destinationParent: destination, ftpLayout: true, keyFile: key(in: root), contentID: contentID)
            let runner = ConversionRunner()
            for item in plan.items {
                _ = try HENBatchExporter.export(item, plan: plan, helper: helper, runner: runner) { _ in }
            }
            XCTAssertEqual(plan.items.map { $0.folderName },
                           ["Xenosaga II (Disc 1) [SLUS_208.92]", "Xenosaga II (Disc 2) [SLUS_211.33]"])
            XCTAssertEqual(try [FileDigest.sha256(one), FileDigest.sha256(two)], before)
            for item in plan.items {
                let detection = try ConversionRunner().inspectEncrypted(item.output, helper: helper)
                XCTAssertEqual(detection.logicalName, "ISO.BIN.ENC")
                XCTAssertEqual(detection.complete, true)
            }
        }
    }
}
