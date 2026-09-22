// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class OperationCoordinatorTests: XCTestCase {
    func testSingleOwnerAtATime() {
        let coordinator = OperationCoordinator()
        let first = coordinator.begin(.convert)
        XCTAssertNotNil(first)
        XCTAssertEqual(coordinator.active, .convert)
        XCTAssertNil(coordinator.begin(.verify))
        XCTAssertEqual(coordinator.active, .convert)
    }

    func testStaleCompletionCannotReleaseNewerOperation() {
        let coordinator = OperationCoordinator()
        guard let stale = coordinator.begin(.convert) else { return XCTFail("first claim failed") }
        XCTAssertTrue(coordinator.end(stale))
        guard let fresh = coordinator.begin(.verify) else { return XCTFail("second claim failed") }
        // The old operation finishing late must not release the new one.
        XCTAssertFalse(coordinator.end(stale))
        XCTAssertTrue(coordinator.isOwner(fresh))
        XCTAssertEqual(coordinator.active, .verify)
        XCTAssertTrue(coordinator.end(fresh))
        XCTAssertNil(coordinator.active)
    }

    func testConcurrentClaimsAdmitExactlyOne() {
        let coordinator = OperationCoordinator()
        let lock = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if coordinator.begin(.build) != nil { lock.lock(); successes += 1; lock.unlock() }
        }
        XCTAssertEqual(successes, 1)
    }

    /// Mirrors the app contract: a package build owns the app, so a utility
    /// started afterwards is refused, and a queued build waits while a
    /// utility owns the slot. Ending the owner reopens the slot.
    func testBuildAndUtilityExcludeEachOtherSymmetrically() {
        let coordinator = OperationCoordinator()
        guard let build = coordinator.begin(.build) else { return XCTFail("build claim failed") }
        XCTAssertNil(coordinator.begin(.verify), "utility must wait while a build owns the slot")
        XCTAssertNil(coordinator.begin(.convert), "utility must wait while a build owns the slot")
        XCTAssertTrue(coordinator.end(build))
        guard let utility = coordinator.begin(.verify) else { return XCTFail("utility claim failed") }
        XCTAssertNil(coordinator.begin(.build), "a queued build must wait while a utility owns the slot")
        XCTAssertTrue(coordinator.end(utility))
        XCTAssertNotNil(coordinator.begin(.build), "the slot reopens for the waiting queue")
    }

    func testCancelledUtilityReleasesTheSlot() {
        let coordinator = OperationCoordinator()
        guard let utility = coordinator.begin(.verify) else { return XCTFail("utility claim failed") }
        XCTAssertTrue(coordinator.end(utility))
        XCTAssertNil(coordinator.active)
        XCTAssertNotNil(coordinator.begin(.convert))
    }
}
