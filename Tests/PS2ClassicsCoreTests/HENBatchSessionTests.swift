// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

/// The HEN queue must survive a restart, and must never present an
/// interrupted conversion as finished work.
final class HENBatchSessionTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func state(items: [HENBatchItem]) -> HENBatchState {
        HENBatchState(items: items, keyFile: URL(fileURLWithPath: "/tmp/klic.bin"),
                      destination: URL(fileURLWithPath: "/tmp/out"),
                      contentID: "UP0001-SLUS12345_00-0000000000000001", folderLayout: true)
    }

    func testRoundTripsQueueAndSettings() throws {
        try temporary { root in
            let file = root.appendingPathComponent("hen-batch.json")
            let iso = root.appendingPathComponent("Game.iso")
            let config = root.appendingPathComponent("Game.CONFIG")
            let original = state(items: [
                HENBatchItem(source: iso, config: config, configSHA256: String(repeating: "a", count: 64),
                             status: .failed, detail: "Stopped.", gameID: "SLUS12345")
            ])
            try HENBatchStore.save(original, to: file)
            let loaded = HENBatchStore.load(from: file)
            XCTAssertFalse(loaded.didRecover, "\(loaded.notes)")
            XCTAssertFalse(loaded.locked)
            XCTAssertEqual(loaded.state, original)
            XCTAssertEqual(loaded.state.items.first?.input.configSHA256, String(repeating: "a", count: 64))
        }
    }

    func testMissingFileLoadsAnEmptyQueueWithoutComplaint() throws {
        try temporary { root in
            let loaded = HENBatchStore.load(from: root.appendingPathComponent("absent.json"))
            XCTAssertTrue(loaded.state.isEmpty)
            XCTAssertFalse(loaded.didRecover)
            XCTAssertFalse(loaded.locked)
        }
    }

    /// The core rule: a conversion interrupted by a crash or quit is restored
    /// as interrupted work, never as a published game.
    func testConvertingRowIsRestoredAsInterruptedNeverComplete() throws {
        try temporary { root in
            let file = root.appendingPathComponent("hen-batch.json")
            let wasConverting = state(items: [
                HENBatchItem(source: root.appendingPathComponent("A.iso"), status: .converting,
                             detail: "Encrypting… 42%")
            ])
            try HENBatchStore.save(wasConverting, to: file)
            let loaded = HENBatchStore.load(from: file)
            let row = try XCTUnwrap(loaded.state.items.first)
            XCTAssertEqual(row.status, .interrupted)
            XCTAssertTrue(row.status.isRetryable)
            // The invariant that matters: it is never presented as finished.
            XCTAssertNotEqual(row.status, .published)
            XCTAssertTrue(row.detail.contains("not complete"), row.detail)
            XCTAssertEqual(loaded.state.finishedCount, 0)
            XCTAssertTrue(HENBatchStatus.converting.restoredAfterRelaunch == .interrupted)
        }
    }

    /// A published claim is only kept while its regular image is still there.
    func testPublishedRowIsDemotedWhenItsFolderIsMissing() throws {
        try temporary { root in
            let file = root.appendingPathComponent("hen-batch.json")
            let gone = state(items: [
                HENBatchItem(source: root.appendingPathComponent("A.iso"), status: .published,
                             detail: "Published.", gameID: "SLUS12345",
                             publishedFolder: root.appendingPathComponent("absent folder"))
            ])
            try HENBatchStore.save(gone, to: file)
            let row = try XCTUnwrap(HENBatchStore.load(from: file).state.items.first)
            XCTAssertEqual(row.status, .interrupted)
            XCTAssertTrue(row.detail.contains("missing"), row.detail)

            let present = state(items: [
                HENBatchItem(source: root.appendingPathComponent("A.iso"), status: .published,
                             detail: "Published.", gameID: "SLUS12345",
                             publishedFolder: root.appendingPathComponent("here"))
            ])
            try FileManager.default.createDirectory(at: root.appendingPathComponent("here"),
                                                    withIntermediateDirectories: true)
            try HENBatchStore.save(present, to: file)
            let empty = try XCTUnwrap(HENBatchStore.load(from: file).state.items.first)
            XCTAssertEqual(empty.status, .interrupted, "an empty folder is not a published game")
            try Data(repeating: 0x4e, count: 1024).write(to: root.appendingPathComponent("here/here.BIN.ENC"))
            let kept = try XCTUnwrap(HENBatchStore.load(from: file).state.items.first)
            XCTAssertEqual(kept.status, .published)
            XCTAssertEqual(HENBatchStore.load(from: file).state.finishedCount, 1)

            try FileManager.default.removeItem(at: root.appendingPathComponent("here/here.BIN.ENC"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("here/here.BIN.ENC"),
                                                       withDestinationURL: root.appendingPathComponent("A.iso"))
            let linked = try XCTUnwrap(HENBatchStore.load(from: file).state.items.first)
            XCTAssertEqual(linked.status, .interrupted, "a linked image is not a published game")
        }
    }

    /// A preflight approval is not persisted, so a restored queue must ask to
    /// be checked again rather than offering a start it cannot honour.
    func testReadyRowIsRestoredAsQueuedBecauseThePlanIsNotPersisted() throws {
        try temporary { root in
            let file = root.appendingPathComponent("hen-batch.json")
            try HENBatchStore.save(state(items: [
                HENBatchItem(source: root.appendingPathComponent("A.iso"), status: .ready,
                             detail: "Checked.", gameID: "SLUS12345")
            ]), to: file)
            let row = try XCTUnwrap(HENBatchStore.load(from: file).state.items.first)
            XCTAssertEqual(row.status, .queued)
            XCTAssertTrue(row.detail.contains("checked again"), row.detail)
        }
    }

    func testDuplicateSourcesAreCollapsedOnRestore() throws {
        try temporary { root in
            let file = root.appendingPathComponent("hen-batch.json")
            let iso = root.appendingPathComponent("A.iso")
            try HENBatchStore.save(state(items: [
                HENBatchItem(source: iso, status: .queued),
                HENBatchItem(source: URL(fileURLWithPath: iso.path + "/"), status: .queued)
            ]), to: file)
            let loaded = HENBatchStore.load(from: file)
            XCTAssertEqual(loaded.state.items.count, 1)
            XCTAssertTrue(loaded.notes.contains { $0.contains("duplicate") }, "\(loaded.notes)")
        }
    }

    /// A damaged file is preserved rather than overwritten, so no queue is
    /// ever silently lost.
    func testDamagedFileIsCopiedAsideAndLocked() throws {
        try temporary { root in
            let file = root.appendingPathComponent("hen-batch.json")
            try Data("not json at all".utf8).write(to: file)
            let loaded = HENBatchStore.load(from: file)
            XCTAssertTrue(loaded.state.isEmpty)
            XCTAssertTrue(loaded.didRecover)
            XCTAssertNotNil(loaded.backup)
            XCTAssertFalse(loaded.locked)
            let backup = try XCTUnwrap(loaded.backup)
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
            XCTAssertTrue(backup.lastPathComponent.contains("unreadable"))
            // The original is still intact, so it can still be recovered.
            XCTAssertEqual(try Data(contentsOf: file), Data("not json at all".utf8))
        }
    }

    func testOversizedFileIsRefusedAndLeftInPlace() throws {
        try temporary { root in
            let file = root.appendingPathComponent("hen-batch.json")
            let filler = Data(repeating: 0x20, count: HENBatchStore.maxBytes + 16)
            try filler.write(to: file)
            let loaded = HENBatchStore.load(from: file)
            XCTAssertTrue(loaded.state.isEmpty)
            XCTAssertTrue(loaded.locked, "an unreadable original must not be overwritten")
            XCTAssertEqual(try Data(contentsOf: file).count, filler.count)
        }
    }

    func testSaveIsAtomicAndRefusesToOversize() throws {
        try temporary { root in
            let file = root.appendingPathComponent("nested/hen-batch.json")
            try HENBatchStore.save(state(items: []), to: file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            var huge = state(items: [])
            huge.contentID = String(repeating: "A", count: HENBatchStore.maxBytes + 64)
            XCTAssertThrowsError(try HENBatchStore.save(huge, to: file))
            // The good file survived the rejected write.
            XCTAssertNoThrow(try JSONDecoder().decode(HENBatchState.self, from: Data(contentsOf: file)))
        }
    }

    func testStatusSemanticsKeepFinishedWorkDistinct() {
        XCTAssertTrue(HENBatchStatus.published.isTerminal)
        XCTAssertFalse(HENBatchStatus.published.isRetryable)
        for status in [HENBatchStatus.queued, .ready, .converting] {
            XCTAssertFalse(status.isTerminal, "\(status.rawValue) must not read as finished")
        }
        for status in [HENBatchStatus.failed, .cancelled, .interrupted] {
            XCTAssertTrue(status.isRetryable, "\(status.rawValue) must be retryable")
        }
        // Unknown future values must not decode onto a completed one.
        XCTAssertNil(HENBatchStatus(rawValue: "Complete"))
    }
}
