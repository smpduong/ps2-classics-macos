// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Destination capability checks: filesystem type, per-file size limit, path
/// component limits and a real write probe. Never writes anything the caller
/// did not ask for: the probe file is removed immediately.
public enum DestinationCheck {
    public struct Limits: Sendable {
        public let fileSystem: String
        public let maxFileBytes: UInt64?
        public let maxComponentBytes: Int
        public let freeBytes: UInt64
    }

    public static let maxComponentBytes = 255
    public static let maxPathBytes = 1000

    public static func limits(for folder: URL) throws -> Limits {
        var info = statfs()
        let result = folder.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path = path else { return -1 }
            return statfs(path, &info)
        }
        guard result == 0 else {
            throw ConversionFailure(message: "The destination folder cannot be inspected. It may be disconnected.")
        }
        let fs = withUnsafeBytes(of: info.f_fstypename) { raw -> String in
            let pointer = raw.bindMemory(to: CChar.self).baseAddress!
            return String(cString: pointer)
        }
        // FAT32 (msdos) caps a single file at 4 GiB - 1; others are far larger.
        let maxFile: UInt64? = fs == "msdos" ? 0xFFFF_FFFF : nil
        let free = UInt64(info.f_bavail) * UInt64(info.f_bsize)
        return Limits(fileSystem: fs, maxFileBytes: maxFile, maxComponentBytes: maxComponentBytes, freeBytes: free)
    }

    /// Validates a destination path and a required size against injected limits
    /// (used by tests to simulate filesystems such as FAT32).
    public static func validate(path: URL, requiredBytes: UInt64, limits: Limits) throws {
        let components = path.pathComponents
        for component in components where component.utf8.count > limits.maxComponentBytes {
            throw ConversionFailure(message: "A folder or file name in the destination is longer than \(limits.maxComponentBytes) bytes, which this filesystem cannot store. Choose a shorter name.")
        }
        guard path.path.utf8.count <= maxPathBytes else {
            throw ConversionFailure(message: "The destination path is too long for the helper's temporary files. Choose a shorter filename or a shallower folder.")
        }
        if let maxFile = limits.maxFileBytes, requiredBytes > maxFile {
            throw ConversionFailure(message: "This destination uses \(limits.fileSystem), which cannot store a file of \(ByteCountFormatter.string(fromByteCount: Int64(requiredBytes), countStyle: .file)). Choose an APFS or Mac OS Extended destination.")
        }
    }

    /// Validates a destination path and a required size against the filesystem.
    public static func validate(path: URL, requiredBytes: UInt64, folder: URL) throws -> Limits {
        let limits = try limits(for: folder)
        try validate(path: path, requiredBytes: requiredBytes, limits: limits)
        return limits
    }

    /// Writes and removes a tiny probe file to prove the folder is writable
    /// before a long build starts.
    public static func probeWritable(folder: URL) throws {
        let probe = folder.appendingPathComponent(".ps2-write-test-\(UUID().uuidString)")
        let published = folder.appendingPathComponent(".ps2-publish-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: probe)
            try? FileManager.default.removeItem(at: published)
        }
        do { try Data([0]).write(to: probe, options: [.withoutOverwriting]) }
        catch { throw ConversionFailure(message: "The destination folder is not writable: \(folder.lastPathComponent). Choose another destination.") }
        if renamex_np(probe.path, published.path, UInt32(RENAME_EXCL)) != 0 {
            let renameError = errno
            guard [ENOTSUP, EOPNOTSUPP, EINVAL].contains(renameError), link(probe.path, published.path) == 0 else {
                let filesystem = (try? limits(for: folder).fileSystem) ?? "unknown"
                throw ConversionFailure(message: "This destination filesystem (\(filesystem)) cannot safely publish output without overwriting. Build on an APFS or Mac OS Extended volume, then copy the completed file.")
            }
        }
    }
}

/// Size estimates that mirror the helper's geometry, so per-file filesystem
/// limits cover encrypted images, memory cards, artwork, metadata and the
/// final package — not just the source bytes. All arithmetic saturates.
public enum BuildEstimates {
    public static let segmentBytes: UInt64 = 16384
    public static let groupSegments: UInt64 = 512
    /// EDAT title record, two memory cards, logo, SFO, artwork, sound, index
    /// names and package framing, with margin.
    public static let fixedOverhead: UInt64 = 256 * 1024 * 1024

    private static func ceilDiv(_ value: UInt64, _ unit: UInt64) -> UInt64 {
        value / unit + (value % unit == 0 ? 0 : 1)
    }

    private static func saturated(_ parts: UInt64...) -> UInt64 {
        var total: UInt64 = 0
        for part in parts {
            let (next, overflow) = total.addingReportingOverflow(part)
            if overflow { return .max }
            total = next
        }
        return total
    }

    private static func scaled(_ value: UInt64, _ factor: UInt64) -> UInt64 {
        let (result, overflow) = value.multipliedReportingOverflow(by: factor)
        return overflow ? .max : result
    }

    /// Prepared stream: source rounded up to a segment plus one LIMG segment.
    public static func preparedBytes(_ original: UInt64) -> UInt64 {
        saturated(scaled(ceilDiv(original, segmentBytes), segmentBytes), segmentBytes)
    }

    /// Encrypted image file: header + per-segment ciphertext + group metadata.
    public static func encodedImageBytes(_ prepared: UInt64) -> UInt64 {
        let segments = ceilDiv(prepared, segmentBytes)
        let groups = ceilDiv(segments, groupSegments)
        return saturated(segmentBytes, scaled(segments, segmentBytes), scaled(groups, segmentBytes))
    }

    /// Final package: encrypted images plus fixed overhead and framing.
    public static func packageBytes(images: [UInt64]) -> UInt64 {
        saturated(images.reduce(UInt64(0)) { saturated($0, $1) }, fixedOverhead, 0x1a0)
    }

    /// Largest single file the build will write (temporary or final).
    public static func largestSingleFile(imageSizes: [UInt64]) -> UInt64 {
        let images = imageSizes.map(encodedImageBytes)
        return max(images.max() ?? 0, packageBytes(images: imageSizes))
    }
}
