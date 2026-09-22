// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// A genuinely bounded read of a local evidence/record file.
///
/// A size check followed by an unbounded `Data(contentsOf:)` is not a hard
/// allocation limit: the file can change between the two operations. This opens
/// the file once, reads through the open descriptor up to a hard cap, and
/// rejects anything that is missing, not a regular file, a symlink, empty, over
/// the cap, or that changes size while being read.
public enum BoundedFile {
    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static func read(_ url: URL, maximum: Int) throws -> Data {
        guard maximum > 0 else { throw Failure("The record size limit is invalid.") }
        guard let identity = FileIdentity.of(url), identity.isRegularFile, !identity.isSymbolicLink else {
            throw Failure("The record is missing, is not a regular file, or is a symbolic link: \(url.lastPathComponent)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw Failure("The record could not be inspected: \(url.lastPathComponent)")
        }
        guard info.st_size > 0, info.st_size <= maximum else {
            throw Failure("The record is empty or larger than the supported limit of \(maximum) bytes: \(url.lastPathComponent)")
        }
        var data = Data()
        while data.count <= maximum {
            let remaining = maximum + 1 - data.count
            guard remaining > 0 else { break }
            let chunk = try handle.read(upToCount: min(1 << 20, remaining)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximum, data.count == Int(info.st_size) else {
            throw Failure("The record changed while it was being read: \(url.lastPathComponent)")
        }
        return data
    }
}
