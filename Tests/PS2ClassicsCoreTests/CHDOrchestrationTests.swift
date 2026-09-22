// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

/// Exercises the CHD image-tool branch of `ConversionRunner`, not just the
/// helper CLI: expansion into a claimed `.ps2-image-*` workspace, the
/// expanded-source override, and cleanup. Opt-in because it needs a helper and
/// a CHD fixture; set PS2_TEST_HELPER and PS2_TEST_CHD to run it.
final class CHDOrchestrationTests: XCTestCase {
    func testEncryptingAChDUsesTheExpandedImageWorkspace() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let helperPath = environment["PS2_TEST_HELPER"], let chdPath = environment["PS2_TEST_CHD"],
              FileManager.default.isExecutableFile(atPath: helperPath),
              FileManager.default.fileExists(atPath: chdPath) else {
            throw XCTSkip("set PS2_TEST_HELPER and PS2_TEST_CHD to run the CHD orchestration test")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = folder.appendingPathComponent("key")
        try Data(repeating: 3, count: 16).write(to: key)
        let destination = folder.appendingPathComponent("disc.enc")

        let request = ConversionRequest(action: .encrypt, source: URL(fileURLWithPath: chdPath),
                                        destination: destination, keyFile: key,
                                        contentID: "UP0001-SLUS12345_00-0000000000000001",
                                        discNumber: 1, logicalName: "ISO.BIN.ENC")
        try ConversionRunner().run(request, helper: URL(fileURLWithPath: helperPath)) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let head = try FileHandle(forReadingFrom: destination).read(upToCount: 4) ?? Data()
        XCTAssertEqual(head, Data([0x50, 0x53, 0x32, 0x00]))   // "PS2\0"
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".ps2-image-") || $0.contains(".partial.") }
        XCTAssertTrue(leftovers.isEmpty, "the image workspace and partials must be cleaned: \(leftovers)")
    }
}
