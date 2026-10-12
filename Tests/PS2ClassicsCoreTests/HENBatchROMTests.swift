// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

/// Local integration coverage against the user's own images.
///
/// These cases are driven by `scripts/test-hen-batch.py`, which supplies
/// `PS2_TEST_ROM_DIR` (and `PS2_TEST_HEN_CONVERT` for the real encryption
/// pass) and independently re-hashes every source around the run. When the
/// environment is absent they return without asserting anything rather than
/// reporting a skip, so a plain `swift test` never implies coverage it did
/// not have. Nothing here is written inside ROMS.
///
/// Synthetic support files are used: a 16-byte key and a matching 36-character
/// content ID that no console has. These cases therefore establish local
/// conversion, publication and verification only — never console playability,
/// and never multi-disc behaviour.
final class HENBatchROMTests: XCTestCase {
    /// The four supplied images, with the boot IDs already recorded by the
    /// read-only inspection workflow.
    private let fixtures: [(name: String, bytes: UInt64, gameID: String)] = [
        ("4x4 Evo 2 (Europe).iso", 501_731_328, "SLES51199"),
        ("Xenosaga Episode 1.iso", 8_468_299_776, "SLUS20469"),
        ("Xenosaga Episode 2 (Disc 1).iso", 4_682_121_216, "SLUS20892"),
        ("Xenosaga Episode 2 (Disc 2).iso", 4_693_164_032, "SLUS21133")
    ]
    private let contentID = "UP0001-SLUS12345_00-0000000000000001"

    private var romDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["PS2_TEST_ROM_DIR"],
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func helper() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["PS2_TEST_HELPER"],
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var convertsImages: Bool {
        ProcessInfo.processInfo.environment["PS2_TEST_HEN_CONVERT"] == "1"
    }

    private func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ps2-hen-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func sources(_ roms: URL) throws -> [URL] {
        for fixture in fixtures {
            let url = roms.appendingPathComponent(fixture.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("missing fixture \(fixture.name)")
            }
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            XCTAssertEqual(size?.uint64Value, fixture.bytes, "\(fixture.name) changed size")
        }
        return try fixtures.map { roms.appendingPathComponent($0.name) }
    }

    private func syntheticSupport(in folder: URL) throws -> URL {
        let key = folder.appendingPathComponent("klic.bin")
        try Data(repeating: 0x5a, count: 16).write(to: key)
        return key
    }

    /// The whole batch is checked before any conversion, against the real
    /// images, and the sources are proven untouched afterwards.
    func testReadOnlyPreflightCoversEverySuppliedImage() throws {
        guard let roms = romDirectory else { return }
        try temporary { root in
            let sources = try self.sources(roms)
            let before = try sources.map { try FileDigest.sha256($0) }
            let plan = try HENBatchExporter.preflight(
                inputs: sources.map { HENBatchInput(source: $0) },
                destinationParent: root, ftpLayout: true,
                keyFile: try syntheticSupport(in: root), contentID: contentID)

            XCTAssertEqual(plan.items.count, self.fixtures.count)
            XCTAssertEqual(plan.items.map { $0.gameID }, self.fixtures.map { $0.gameID })
            XCTAssertEqual(plan.imageFolder,
                           plan.readyFolder.appendingPathComponent("dev_hdd0/PS2ISO"))
            // webMAN's upper-case bracketed form must terminate every name.
            XCTAssertEqual(plan.items.map { $0.imageName }, [
                "4x4 Evo 2 (Europe) [SLES_511.99].BIN.ENC",
                "Xenosaga Episode 1 [SLUS_204.69].BIN.ENC",
                "Xenosaga Episode 2 (Disc 1) [SLUS_208.92].BIN.ENC",
                "Xenosaga Episode 2 (Disc 2) [SLUS_211.33].BIN.ENC"
            ])
            XCTAssertGreaterThan(plan.requiredBytes, 18_000_000_000)
            // Preflight inspects and hashes, but creates no export folder.
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.readyFolder.path))
            XCTAssertEqual(try sources.map { try FileDigest.sha256($0) }, before)
            print("HEN-BATCH-PREFLIGHT {\"cases\":\(plan.items.count),\"sourceHashesBound\":true}")
        }
    }

    /// A real batch: every supplied image is encrypted with the standalone
    /// base profile, verified with the bundled helper, published beside its
    /// optional CONFIG, and re-checked against its preflight hash.
    func testRealBatchConvertsAndPublishesEverySuppliedImage() throws {
        guard let roms = romDirectory, let helper = helper(), convertsImages else { return }
        try temporary { root in
            let sources = try self.sources(roms)
            let before = try sources.map { try FileDigest.sha256($0) }
            let key = try syntheticSupport(in: root)
            // One plain unencrypted CONFIG, to exercise the sidecar path.
            let config = root.appendingPathComponent("Xeno.CONFIG")
            try Data(repeating: 0x21, count: 64).write(to: config)
            let plan = try HENBatchExporter.preflight(
                inputs: [HENBatchInput(source: sources[2], config: config,
                                       configSHA256: try HENBatchExporter.configFingerprint(config))]
                    + sources.enumerated().filter { $0.offset != 2 }
                        .map { HENBatchInput(source: $0.element) },
                destinationParent: root, ftpLayout: true, keyFile: key, contentID: contentID)

            let runner = ConversionRunner()
            var seconds = 0.0
            for item in plan.items {
                let started = Date()
                let folder = try HENBatchExporter.export(item, plan: plan, helper: helper,
                                                         runner: runner) { _ in }
                seconds += Date().timeIntervalSince(started)
                XCTAssertTrue(FileManager.default.fileExists(atPath: item.output.path))
                // Each published image must be the verified base profile.
                let detection = try ConversionRunner().inspectEncrypted(item.output, helper: helper)
                XCTAssertEqual(detection.logicalName, "ISO.BIN.ENC")
                XCTAssertEqual(detection.complete, true)
                XCTAssertTrue(folder.path.hasPrefix(plan.imageFolder.path))
                if let sidecar = item.configSidecarName {
                    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(sidecar)).count, 64)
                }
            }
            // No staged private folder may survive, and every source must be
            // byte-identical to what preflight saw.
            let published = try FileManager.default.contentsOfDirectory(atPath: plan.imageFolder.path)
            XCTAssertFalse(published.contains { $0.hasPrefix(".ps2-hen-") }, "\(published)")
            XCTAssertEqual(published.count, plan.items.count)
            XCTAssertEqual(try sources.map { try FileDigest.sha256($0) }, before)

            let report = """
            {"cases": \(plan.items.count), "seconds": \(Int(seconds)), \
            "profile": "ISO.BIN.ENC", "layout": "dev_hdd0/PS2ISO", "consoleTested": false}
            """
            print("HEN-BATCH-REAL \(report)")
        }
    }

    /// A cancelled real batch must publish nothing and keep every source.
    func testCancelledRealBatchPublishesNothing() throws {
        guard let roms = romDirectory, let helper = helper(), convertsImages else { return }
        try temporary { root in
            let sources = try self.sources(roms)
            let before = try sources.map { try FileDigest.sha256($0) }
            let plan = try HENBatchExporter.preflight(
                inputs: sources.map { HENBatchInput(source: $0) },
                destinationParent: root, ftpLayout: true,
                keyFile: try syntheticSupport(in: root), contentID: contentID)
            let runner = ConversionRunner()
            runner.cancel()
            for item in plan.items {
                XCTAssertThrowsError(try HENBatchExporter.export(item, plan: plan, helper: helper,
                                                                 runner: runner) { _ in })
                XCTAssertFalse(FileManager.default.fileExists(atPath: item.folder.path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.readyFolder.path))
            XCTAssertEqual(try sources.map { try FileDigest.sha256($0) }, before)
        }
    }
}
