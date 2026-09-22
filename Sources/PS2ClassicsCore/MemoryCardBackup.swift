// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

/// Copy-first whole-card backups. Checks framing and byte integrity, not the
/// health of individual saves. Restoration always creates a new card file.
public enum MemoryCardBackup {
    public struct Record: Codable, Equatable, Sendable {
        public let version: Int
        public let created: Date
        public let originalName: String
        public let file: String
        public let bytes: Int
        public let sha256: String
    }
    private static let maximum = 70 * 1024 * 1024

    private static func copy(_ source: URL, _ destination: URL, runner: ConversionRunner,
                             progress: @escaping @Sendable (ConversionProgress) -> Void) throws -> (Int, String) {
        guard source.isFileURL else { throw ConversionFailure(message: "Choose a local memory-card file.") }
        let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard inputFD >= 0 else { throw ConversionFailure(message: "Cannot read the card, or it is a symbolic link.") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var status = stat()
        guard fstat(inputFD, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size > 0, status.st_size <= maximum else {
            throw ConversionFailure(message: "Choose a regular 8–64 MiB PS2 card with ECC.")
        }
        let count = Int(status.st_size)
        guard [8,16,32,64].contains(where: { count == $0 * 1024 * 1024 / 512 * 528 || count == $0 * 1024 * 1024 / 512 * 528 + 16384 }) else {
            throw ConversionFailure(message: "The card size does not match a supported PS2 card with ECC.")
        }
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw ConversionFailure(message: "The backup destination already exists or cannot be created.") }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var hash = SHA256(), copied = 0
        while copied < count {
            try runner.checkCancellation()
            let block = try input.read(upToCount: min(1024 * 1024, count-copied)) ?? Data()
            guard !block.isEmpty else { throw ConversionFailure(message: "The card changed or became unreadable while copying.") }
            try output.write(contentsOf: block); hash.update(data: block); copied += block.count
            progress(ConversionProgress(stage: "Copying card", fraction: Double(copied) / Double(count) * 0.5))
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw ConversionFailure(message: "The card grew while copying.") }
        try output.synchronize(); try output.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard try FileDigest.sha256(source, cancelled: { try runner.checkCancellation() }) == digest,
              try FileDigest.sha256(destination, cancelled: { try runner.checkCancellation() }) == digest else {
            throw ConversionFailure(message: "The card changed or its copy did not verify. No result was published.")
        }
        return (count, digest)
    }

    private static func checkedWorkspace(_ destination: URL) throws -> URL {
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else {
            throw ConversionFailure(message: "Choose a new destination. Existing cards and backups are never replaced.")
        }
        let parent = destination.deletingLastPathComponent()
        try DestinationCheck.probeWritable(folder: parent)
        let workspace = parent.appendingPathComponent(".ps2-card-backup-" + UUID().uuidString)
        guard mkdir(workspace.path, 0o700) == 0 else { throw ConversionFailure(message:"Cannot create a private card-backup workspace.") }
        return workspace
    }

    private static func validate(_ file: URL, encrypted: Bool, helper: URL, runner: ConversionRunner) throws {
        let verified = file.deletingLastPathComponent().appendingPathComponent("validation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: verified) }
        try runner.run(arguments: [encrypted ? "vmc-decrypt" : "vmc-encrypt", file.path, verified.path], helper: helper, progress: { _ in })
        try runner.checkCancellation()
    }

    @discardableResult
    public static func create(source: URL, destination: URL, helper: URL, runner: ConversionRunner,
                              progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) throws -> Record {
        let workspace = try checkedWorkspace(destination)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let payload = workspace.appendingPathComponent("card")
        let (bytes, hash) = try copy(source, payload, runner: runner, progress: progress)
        let input = try FileHandle(forReadingFrom: payload)
        let header = try input.read(upToCount: 28) ?? Data(); try input.close()
        let encrypted = header != Data("Sony PS2 Memory Card Format ".utf8)
        progress(ConversionProgress(stage: "Checking card format", fraction: 0.6))
        try validate(payload, encrypted: encrypted, helper: helper, runner: runner)
        let name = encrypted ? "card.VME" : "card.VMC"
        try FileManager.default.moveItem(at: payload, to: workspace.appendingPathComponent(name))
        let record = Record(version: 1, created: Date(), originalName: source.lastPathComponent, file: name, bytes: bytes, sha256: hash)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: workspace.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try runner.checkCancellation()
        guard renamex_np(workspace.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ConversionFailure(message: "Cannot publish the backup without replacing another item. Choose a new name on APFS or Mac OS Extended.")
        }
        progress(ConversionProgress(stage: "Backup verified", fraction: 1))
        return record
    }

    public static func record(in backup: URL) throws -> Record {
        guard backup.isFileURL,
              let values = try? backup.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            throw ConversionFailure(message: "Choose a regular .ps2cardbackup folder.")
        }
        let record = try JSONDecoder().decode(Record.self, from: BoundedFile.read(backup.appendingPathComponent("manifest.json"), maximum: 65536))
        guard record.version == 1, ["card.VMC", "card.VME"].contains(record.file),
              record.bytes > 0, record.bytes <= maximum,
              record.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ConversionFailure(message: "The backup manifest is unsupported or damaged.")
        }
        return record
    }

    public static func restore(backup: URL, destination: URL, helper: URL, runner: ConversionRunner,
                               progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) throws {
        let record = try record(in: backup)
        let workspace = try checkedWorkspace(destination)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let payload = workspace.appendingPathComponent("restored-card")
        let (bytes, hash) = try copy(backup.appendingPathComponent(record.file), payload, runner: runner, progress: progress)
        guard bytes == record.bytes, hash == record.sha256 else {
            throw ConversionFailure(message: "The backup does not match its recorded checksum. No card was restored.")
        }
        try validate(payload, encrypted: record.file == "card.VME", helper: helper, runner: runner)
        try runner.checkCancellation()
        if renamex_np(payload.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let failure = errno
            guard [ENOTSUP, EOPNOTSUPP, EINVAL].contains(failure), link(payload.path, destination.path) == 0 else {
                throw ConversionFailure(message: "Cannot restore without replacing an existing file. Choose a new filename.")
            }
        }
        progress(ConversionProgress(stage: "Restored copy verified", fraction: 1))
    }
}
