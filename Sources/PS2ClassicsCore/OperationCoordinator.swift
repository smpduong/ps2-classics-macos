// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Single-slot operation ownership. A token identifies the one operation that
/// currently owns a shared resource (a window's busy state or the app's utility
/// slot). A stale completion can only release ownership it still holds, so it
/// can never clear a newer operation's state.
public final class OperationCoordinator: @unchecked Sendable {
    public enum Kind: String, Sendable { case inspect, convert, verify, detect, build }

    private let lock = NSLock()
    private var owner: UUID?
    private var ownerKind: Kind?

    public init() {}

    /// Claims the slot, or returns nil if another operation already holds it.
    @discardableResult
    public func begin(_ kind: Kind) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return nil }
        let token = UUID()
        owner = token; ownerKind = kind
        return token
    }

    public func isOwner(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return owner == token
    }

    /// Releases the slot only if `token` still owns it. Returns whether it did.
    @discardableResult
    public func end(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == token else { return false }
        owner = nil; ownerKind = nil
        return true
    }

    public var active: Kind? {
        lock.lock(); defer { lock.unlock() }
        return ownerKind
    }
}

/// One cancellation signal shared across every stage of an operation (hashing
/// passes, helper processes). Cancelling sets the flag and terminates the
/// helper; each stage checks the same flag, so no stage can hold the
/// operation slot after the user asked to stop.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    public func check() throws {
        lock.lock(); defer { lock.unlock() }
        if flag { throw ConversionFailure(message: "Cancelled. The package was left untouched.") }
    }
}
