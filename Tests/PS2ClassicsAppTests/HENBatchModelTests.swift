// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import PS2ClassicsCore
@testable import PS2ClassicsApp

@MainActor
final class HENBatchModelTests: XCTestCase {
    func testUnreadableSavedQueueCannotBeOverwrittenByAnEdit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ps2-hen-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = root.appendingPathComponent("hen-batch.json")
        let original = Data(repeating: 0x20, count: HENBatchStore.maxBytes + 1)
        try original.write(to: saved)
        let model = HENBatchModel(storeURL: saved)
        XCTAssertTrue(model.recoveryLocked)
        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.canCheck)

        let iso = root.appendingPathComponent("game.iso")
        try Data([1]).write(to: iso)
        model.add([iso])
        model.setContentID("UP0001-SLUS12345_00-0000000000000001")
        model.removeAll()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: saved), original)
    }
}
