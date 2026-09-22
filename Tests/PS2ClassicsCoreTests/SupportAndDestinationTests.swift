// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class CancelFlagTests: XCTestCase {
    func testFlagStartsClearAndTripsOnce() throws {
        let flag = CancelFlag()
        XCTAssertFalse(flag.isCancelled)
        XCTAssertNoThrow(try flag.check())
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
        XCTAssertThrowsError(try flag.check()) { error in
            XCTAssertTrue(error.localizedDescription.lowercased().contains("cancel"))
        }
    }

    func testDigestReportsProgressAndHonoursCancel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.bin")
        try Data(repeating: 7, count: 20 * 1024 * 1024).write(to: file)
        var seen: [(UInt64, UInt64)] = []
        let digest = try FileDigest.sha256(file, progress: { seen.append(($0, $1)) })
        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(seen.last?.1, 20 * 1024 * 1024)
        XCTAssertTrue(seen.allSatisfy { $0.0 <= $0.1 })
        for i in 1..<seen.count { XCTAssertGreaterThanOrEqual(seen[i].0, seen[i - 1].0) }
        // Cancelling mid-hash aborts with a cancel error, never a digest.
        let flag = CancelFlag()
        var calls = 0
        XCTAssertThrowsError(try FileDigest.sha256(file, cancelled: {
            calls += 1
            if calls > 1 { try flag.check() }
            flag.cancel()
        })) { error in
            XCTAssertTrue(error.localizedDescription.lowercased().contains("cancel"), "\(error)")
        }
    }
}

final class SupportAndDestinationTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path); try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func makeSupport(in folder: URL) throws -> SupportFiles {
        try Data(repeating: 1, count: 16).write(to: folder.appendingPathComponent("klic.bin"))
        try Data(repeating: 2, count: 16).write(to: folder.appendingPathComponent("UP0001-SLUS12345_00-0000000000000001.rap"))
        try Data([3]).write(to: folder.appendingPathComponent("PS3LOGO.DAT"))
        try Data([4]).write(to: folder.appendingPathComponent("SCEVMC0.VMC"))
        var support = SupportFiles()
        try support.importFolder(folder)
        return support
    }

    func testProfileRoundTripUniquenessAndValidation() throws {
        try temporary { folder in
            let storeURL = folder.appendingPathComponent("profiles.json")
            let support = try makeSupport(in: folder)
            let store = SupportProfileStore(url: storeURL)
            XCTAssertTrue(store.profiles.isEmpty)
            try store.add(name: "Home set", support: support)
            XCTAssertThrowsError(try store.add(name: "home set", support: support))
            XCTAssertThrowsError(try store.add(name: "  ", support: support))
            let reopened = SupportProfileStore(url: storeURL)
            XCTAssertEqual(reopened.profiles.count, 1)
            XCTAssertEqual(reopened.profiles[0].contentID, support.contentID)
            XCTAssertTrue(reopened.validate(reopened.profiles[0]).isEmpty)
            // A moved file is reported before the profile is applied.
            try FileManager.default.removeItem(at: folder.appendingPathComponent("klic.bin"))
            XCTAssertTrue(reopened.validate(reopened.profiles[0]).contains { $0.contains("klicensee") })
            try Data(repeating: 9, count: 17).write(to: folder.appendingPathComponent("klic.bin"))
            XCTAssertTrue(reopened.validate(reopened.profiles[0]).contains { $0.contains("expected 16") })
            try reopened.remove(id: reopened.profiles[0].id)
            XCTAssertTrue(SupportProfileStore(url: storeURL).profiles.isEmpty)
        }
    }

    func testDestinationLimitsAndProbe() throws {
        try temporary { folder in
            let limits = try DestinationCheck.limits(for: folder)
            XCTAssertFalse(limits.fileSystem.isEmpty)
            XCTAssertEqual(limits.maxComponentBytes, 255)
            // A component longer than the filesystem allows is refused before building.
            let longName = String(repeating: "a", count: 300) + ".pkg"
            XCTAssertThrowsError(try DestinationCheck.validate(path: folder.appendingPathComponent(longName),
                                                               requiredBytes: 1, folder: folder))
            XCTAssertNoThrow(try DestinationCheck.validate(path: folder.appendingPathComponent("Game.pkg"),
                                                           requiredBytes: 1, folder: folder))
            // A FAT32-style per-file cap is enforced when known.
            let fat = DestinationCheck.Limits(fileSystem: "msdos", maxFileBytes: 0xFFFF_FFFF,
                                              maxComponentBytes: 255, freeBytes: 1 << 40)
            XCTAssertThrowsError(try DestinationCheck.validate(path: folder.appendingPathComponent("Game.pkg"),
                                                               requiredBytes: 0x1_0000_0000, limits: fat)) { error in
                XCTAssertTrue(error.localizedDescription.contains("msdos"), error.localizedDescription)
            }
            XCTAssertNoThrow(try DestinationCheck.validate(path: folder.appendingPathComponent("Game.pkg"),
                                                           requiredBytes: 1024, limits: fat))
            try DestinationCheck.probeWritable(folder: folder)
            let readOnly = folder.appendingPathComponent("readonly")
            try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
            XCTAssertThrowsError(try DestinationCheck.probeWritable(folder: readOnly))
        }
    }

    /// Real mounted-volume check, gated on PS2_TEST_VOLUME pointing at a mounted
    /// external filesystem (e.g. an exFAT or FAT32 disk image). Distinguishes
    /// actual filesystem behaviour from injected limits.
    func testRealMountedVolumeFilesystemDetection() throws {
        guard let path = ProcessInfo.processInfo.environment["PS2_TEST_VOLUME"] else {
            throw XCTSkip("set PS2_TEST_VOLUME to a mounted volume to run the real-volume check")
        }
        let url = URL(fileURLWithPath: path)
        let limits = try DestinationCheck.limits(for: url)
        XCTAssertFalse(limits.fileSystem.isEmpty)
        XCTAssertGreaterThan(limits.freeBytes, 0)
        if limits.fileSystem == "exfat" {
            XCTAssertThrowsError(try DestinationCheck.probeWritable(folder: url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("cannot safely publish"))
            }
        } else {
            XCTAssertNoThrow(try DestinationCheck.probeWritable(folder: url))
        }
        if limits.fileSystem == "msdos" {
            XCTAssertEqual(limits.maxFileBytes, 0xFFFF_FFFF, "FAT32 must report its 4 GiB per-file cap")
            XCTAssertThrowsError(try DestinationCheck.validate(path: url.appendingPathComponent("Game.pkg"),
                                                               requiredBytes: 0x1_0000_0000, limits: limits)) { error in
                XCTAssertTrue(error.localizedDescription.contains("msdos"), error.localizedDescription)
            }
            XCTAssertNoThrow(try DestinationCheck.validate(path: url.appendingPathComponent("Game.pkg"),
                                                           requiredBytes: 1024, limits: limits))
        }
    }

    func testProfilePreservesRealSourceFolder() throws {
        try temporary { folder in
            let support = try makeSupport(in: folder)
            XCTAssertEqual(support.sourceFolder?.path, folder.path)
            let store = SupportProfileStore(url: folder.appendingPathComponent("profiles.json"))
            let saved = try store.add(name: "Home set", support: support)
            XCTAssertEqual(saved.sourceFolder, folder.path)
            XCTAssertTrue(saved.importedTogether)
            let restored = SupportProfileStore(url: folder.appendingPathComponent("profiles.json")).profiles[0]
            XCTAssertEqual(restored.support.sourceFolder?.path, folder.path, "applying a profile must restore the real folder, never a fabricated one")
            // Individually picked files record no folder.
            var mixed = support
            mixed.sourceFolder = nil
            let mixedSaved = try SupportProfileStore(url: folder.appendingPathComponent("other.json")).add(name: "Mixed", support: mixed)
            XCTAssertNil(mixedSaved.sourceFolder)
            XCTAssertFalse(mixedSaved.importedTogether)
        }
    }

    func testProfileValidationRejectsNonRegularFiles() throws {
        try temporary { folder in
            let support = try makeSupport(in: folder)
            let store = SupportProfileStore(url: folder.appendingPathComponent("profiles.json"))
            let profile = try store.add(name: "Home set", support: support)
            // A directory passed off as the klicensee must be refused.
            var tampered = profile
            tampered.key = folder
            XCTAssertTrue(store.validate(tampered).contains { $0.contains("not a regular file") })
            // A symlink is refused even when it resolves to a valid file.
            let link = folder.appendingPathComponent("linked-key")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("klic.bin"))
            tampered.key = link
            XCTAssertTrue(store.validate(tampered).contains { $0.contains("not a regular file") })
        }
    }

    func testBuildEstimatesMirrorHelperGeometry() {
        // 2048-byte image: padded to one segment, plus one LIMG segment.
        XCTAssertEqual(BuildEstimates.preparedBytes(2048), 2 * 16384)
        // Encoded file: header + per-segment ciphertext + one group block.
        XCTAssertEqual(BuildEstimates.encodedImageBytes(BuildEstimates.preparedBytes(2048)), 4 * 16384)
        XCTAssertEqual(BuildEstimates.encodedImageBytes(16384), 3 * 16384)
        // DVD9-scale values stay far below any filesystem cap and grow with input.
        let dvd9: UInt64 = 8_468_299_776
        let image = BuildEstimates.encodedImageBytes(BuildEstimates.preparedBytes(dvd9))
        XCTAssertGreaterThan(image, dvd9)
        XCTAssertLessThan(image, 9_000_000_000)
        let package = BuildEstimates.packageBytes(images: [image])
        XCTAssertGreaterThan(package, image)
        // A FAT32 volume cannot hold a DVD9-scale file.
        let fat = DestinationCheck.Limits(fileSystem: "msdos", maxFileBytes: 0xFFFF_FFFF,
                                          maxComponentBytes: 255, freeBytes: 1 << 40)
        XCTAssertThrowsError(try DestinationCheck.validate(path: URL(fileURLWithPath: "/tmp/Game.pkg"),
                                                           requiredBytes: image, limits: fat))
        XCTAssertNoThrow(try DestinationCheck.validate(path: URL(fileURLWithPath: "/tmp/Game.pkg"),
                                                       requiredBytes: BuildEstimates.encodedImageBytes(501_760_000),
                                                       limits: fat))
        // Overflow saturates instead of wrapping.
        XCTAssertEqual(BuildEstimates.encodedImageBytes(.max), .max)
    }
}
