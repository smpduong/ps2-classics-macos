// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class MemoryCardBackupTests: XCTestCase {
    func temporary(_ body: (URL, URL) throws -> Void) throws {
        guard let helper = ProcessInfo.processInfo.environment["PS2_TEST_HELPER"] else { throw XCTSkip("set PS2_TEST_HELPER") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, URL(fileURLWithPath: helper))
    }
    func card(_ root: URL) throws -> URL {
        var bytes = Data(repeating: 0, count: 8*1024*1024/512*528)
        bytes.replaceSubrange(0..<28, with: Data("Sony PS2 Memory Card Format ".utf8))
        let url = root.appendingPathComponent("source.VMC"); try bytes.write(to: url); return url
    }
    func testBackupRestorePreservesRawAndEncryptedCards() throws {
        try temporary { root, helper in
            let raw = try card(root), encrypted = root.appendingPathComponent("source.VME")
            try ConversionRunner().run(arguments: ["vmc-encrypt",raw.path,encrypted.path],helper:helper,progress:{ _ in })
            for source in [raw, encrypted] {
                let original = try FileDigest.sha256(source)
                let backup = root.appendingPathComponent(source.pathExtension+".ps2cardbackup")
                let record = try MemoryCardBackup.create(source:source,destination:backup,helper:helper,runner:ConversionRunner())
                XCTAssertEqual(record.sha256,original)
                XCTAssertEqual(record.file,"card."+source.pathExtension)
                let restored = root.appendingPathComponent("restored."+source.pathExtension)
                try MemoryCardBackup.restore(backup:backup,destination:restored,helper:helper,runner:ConversionRunner())
                XCTAssertEqual(try FileDigest.sha256(restored),original)
                XCTAssertEqual(try FileDigest.sha256(source),original)
                XCTAssertThrowsError(try MemoryCardBackup.restore(backup:backup,destination:restored,helper:helper,runner:ConversionRunner()))
            }
        }
    }
    func testDamagedPayloadAndTraversalManifestCannotRestore() throws {
        try temporary { root, helper in
            let source = try card(root), backup = root.appendingPathComponent("backup.ps2cardbackup"), output = root.appendingPathComponent("restored.VMC")
            try MemoryCardBackup.create(source:source,destination:backup,helper:helper,runner:ConversionRunner())
            let handle = try FileHandle(forWritingTo:backup.appendingPathComponent("card.VMC")); try handle.seek(toOffset:4096); try handle.write(contentsOf:Data([9])); try handle.close()
            XCTAssertThrowsError(try MemoryCardBackup.restore(backup:backup,destination:output,helper:helper,runner:ConversionRunner()))
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
            let manifest=backup.appendingPathComponent("manifest.json")
            var json=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any]
            json["file"]="../source.VMC"; try JSONSerialization.data(withJSONObject:json).write(to:manifest)
            XCTAssertThrowsError(try MemoryCardBackup.record(in:backup))
        }
    }
    func testCancelledBackupAndSymlinkLeaveNoOutput() throws {
        try temporary { root, helper in
            let source=try card(root), output=root.appendingPathComponent("backup.ps2cardbackup"), runner=ConversionRunner()
            XCTAssertThrowsError(try MemoryCardBackup.create(source:source,destination:output,helper:helper,runner:runner) { _ in runner.cancel() })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["source.VMC"])
            let link=root.appendingPathComponent("link.VMC");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
            XCTAssertThrowsError(try MemoryCardBackup.create(source:link,destination:output,helper:helper,runner:ConversionRunner()))
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        }
    }
}
