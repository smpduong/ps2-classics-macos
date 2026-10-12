// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// One ISO queued for the standalone PS2 Classic webMAN MOD on HEN workflow.
/// This preset always seals the base `ISO.BIN.ENC` profile: a numbered
/// package-disc profile and the PKG container both belong to the separate
/// build-queue workflow and are deliberately unreachable from here.
public struct HENBatchInput: Sendable {
    public let id: UUID
    public let source: URL
    public let config: URL?
    /// Fingerprint observed when the CONFIG was chosen. A mismatch is a
    /// deliberate, explicit rejection rather than a silent re-read.
    public let configSHA256: String?

    public init(id: UUID = UUID(), source: URL, config: URL? = nil, configSHA256: String? = nil) {
        self.id = id; self.source = source; self.config = config; self.configSHA256 = configSHA256
    }
}

/// A preflight-approved game. Produced only by `preflight`, so every field
/// below has already been checked against the source, key and destination.
public struct HENPreparedItem: Sendable {
    public let id: UUID
    public let source: URL
    public let gameID: String
    public let sourceBytes: UInt64
    /// Full source digest captured during the reviewed preflight. A same-size
    /// ISO replacement with the same game ID must not inherit that approval.
    public let sourceSHA256: String
    public let folder: URL
    public let imageName: String
    public let config: URL?
    public let configSHA256: String?
    /// Captured at preflight so publication never re-reads a file that could
    /// change underneath the copy.
    public let configBytes: Data?

    public var output: URL { folder.appendingPathComponent(imageName) }
    public var configSidecarName: String? { configBytes == nil ? nil : imageName + ".CONFIG" }
    public var displayGameID: String { HENBatchExporter.displayGameID(gameID) }
    public var folderName: String { folder.lastPathComponent }
    public var estimatedOutputBytes: UInt64 {
        BuildEstimates.encodedImageBytes(BuildEstimates.preparedBytes(sourceBytes))
    }
}

/// A fully checked batch, shown to the user for review before any conversion
/// starts. Nothing here has been converted yet.
public struct HENBatchPlan: Sendable {
    public let items: [HENPreparedItem]
    public let readyFolder: URL
    public let imageFolder: URL
    public let keyFile: URL
    public let keySHA256: String
    public let contentID: String
    /// Folder-only nesting that mirrors the documented console path. It
    /// arranges directories and nothing else: no upload, no credentials.
    public let folderLayout: Bool
    /// Bytes the whole batch will write, including the CONFIG sidecars and a
    /// fixed working margin.
    public let requiredBytes: UInt64
    public let freeBytes: UInt64
    public let fileSystem: String
    /// Non-blocking observations worth reading before the user commits.
    public let notes: [String]

    /// Where the user should copy these files for a HEN console. Plain folder
    /// guidance only; this workflow never transfers anything.
    public var consoleDestination: String {
        folderLayout ? "/dev_hdd0/PS2ISO" : "/dev_hdd0/PS2ISO (copy each game folder's contents in)"
    }
}

public enum HENBatchExporter {
    private static let fm = FileManager.default
    /// webMAN MOD reads a CONFIG as plain sidecar data next to its image.
    public static let maxConfigBytes = 1024 * 1024
    /// Free-space margin for helper temporaries, kept well above one segment.
    public static let workingMarginBytes: UInt64 = 128 * 1024 * 1024
    public static let maxBatchSize = 50
    public static let readyFolderName = "Ready for Super Slim"

    // MARK: - CONFIG validation

    /// webMAN expects a plain, unencrypted CONFIG beside the image, named
    /// exactly `<image>.CONFIG`. Empty, oversized, unreadable and
    /// already-sealed files are each rejected with their own message, so a
    /// failure is never reported as an unrelated "unsupported" case.
    public static func configFingerprint(_ url: URL) throws -> String {
        FileDigest.sha256(data: try configBytes(url))
    }

    public static func configBytes(_ url: URL) throws -> Data {
        guard url.isFileURL else {
            throw ConversionFailure(message: "Choose a local CONFIG file on this Mac.")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ConversionFailure(message: "The CONFIG must be a regular file, not a link or folder: \(url.lastPathComponent)")
        }
        let size = Int64(info.st_size)
        guard size > 0 else {
            throw ConversionFailure(message: "The CONFIG is empty: \(url.lastPathComponent). Choose a CONFIG with contents.")
        }
        guard size <= Int64(maxConfigBytes) else {
            throw ConversionFailure(message: "The CONFIG is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), larger than the \(ByteCountFormatter.string(fromByteCount: Int64(maxConfigBytes), countStyle: .file)) limit for a plain CONFIG: \(url.lastPathComponent)")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw ConversionFailure(message: "The CONFIG cannot be read: \(url.lastPathComponent)") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxConfigBytes)) ?? nil
        guard let data, data.count == size else {
            throw ConversionFailure(message: "The CONFIG changed while it was being read: \(url.lastPathComponent). Choose it again.")
        }
        // This app's own sealed CONFIG records are not plain webMAN data.
        guard data.prefix(4) != Data([80, 83, 50, 0]), data.prefix(4) != Data([78, 80, 68, 0]) else {
            throw ConversionFailure(message: "Choose an unencrypted CONFIG, not a sealed PS2/NPD record: \(url.lastPathComponent)")
        }
        return data
    }

    // MARK: - Naming

    /// A single safe path component. webMAN MOD recognises the bracketed,
    /// upper-case title ID that terminates the name, which is why the ID is
    /// always appended last.
    static func safeStem(_ source: URL) -> String {
        let original = source.deletingPathExtension().lastPathComponent
        var result = ""
        for character in original {
            let replacement: String
            if character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
                replacement = "-"
            } else if character == ":" || character == "\\" || character == "/" {
                replacement = "-"
            } else {
                replacement = String(character)
            }
            if result.utf8.count + replacement.utf8.count > 120 { break }
            result += replacement
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return result.isEmpty ? "Game" : result
    }

    /// `SLUS20892` -> `SLUS_208.92`, the upper-case bracketed form webMAN MOD
    /// parses for its CONFIG database and cover lookup.
    static func displayGameID(_ id: String) -> String {
        let letters = id.prefix(4)
        let digits = id.suffix(5)
        return "\(letters)_\(digits.prefix(3)).\(digits.suffix(2))"
    }

    private static func requireDirectoryOrAbsent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw ConversionFailure(message: "The output path is already a file or symbolic link: \(url.path)")
            }
        } else if errno != ENOENT {
            throw ConversionFailure(message: "Cannot inspect output path: \(url.path)")
        }
    }

    // MARK: - Capacity

    /// Bytes the whole batch must write, saturating rather than wrapping.
    public static func requiredBytes(for items: [HENPreparedItem]) -> UInt64 {
        var total: UInt64 = workingMarginBytes
        for item in items {
            var component = item.estimatedOutputBytes
            if let config = item.configBytes {
                let (sum, overflow) = component.addingReportingOverflow(UInt64(config.count))
                component = overflow ? UInt64.max : sum
            }
            let (total2, overflow) = total.addingReportingOverflow(component)
            total = overflow ? UInt64.max : total2
        }
        return total
    }

    /// Preflight evaluates this with the real per-volume limits, so a
    /// destination that cannot hold the whole batch is refused before the
    /// first conversion rather than part-way through it.
    public static func checkCapacity(requiredBytes: UInt64, freeBytes: UInt64) throws {
        guard freeBytes > requiredBytes else {
            throw ConversionFailure(message: "This batch needs about \(formatted(requiredBytes)) free at the destination but only \(formatted(freeBytes)) is available. Choose a larger volume or a smaller batch.")
        }
    }

    public static func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    // MARK: - Cancellation

    /// Single place that decides whether a thrown error was a cancellation, so
    /// a batch never records a user cancel as a conversion failure.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let failure = error as? ConversionFailure else { return false }
        return failure.message.lowercased().hasPrefix("cancelled")
    }

    // MARK: - Preflight

    /// Inspects every ISO, key, CONFIG and output path before the first long
    /// job. The ISO check is structural, not a full-disc integrity or console
    /// compatibility guarantee. Nothing is created and no source is written.
    public static func preflight(inputs: [HENBatchInput], destinationParent: URL,
                                 ftpLayout: Bool, keyFile: URL, contentID: String,
                                 cancelled: () throws -> Void = {}) throws -> HENBatchPlan {
        guard !inputs.isEmpty, inputs.count <= maxBatchSize else {
            throw ConversionFailure(message: "Add 1–\(maxBatchSize) PS2 ISO files to this batch.")
        }
        guard destinationParent.isFileURL, keyFile.isFileURL else {
            throw ConversionFailure(message: "Choose a local destination folder and binary klicensee.")
        }
        try cancelled()
        try requireDirectoryOrAbsent(destinationParent)
        guard fm.fileExists(atPath: destinationParent.path) else {
            throw ConversionFailure(message: "The destination folder does not exist: \(destinationParent.path)")
        }
        try DestinationCheck.probeWritable(folder: destinationParent)
        let key = try validateKey(keyFile)
        let keyHash = FileDigest.sha256(data: key)
        // Reject an unusable content ID before any ISO is inspected, so the
        // user is not told a batch is ready when the helper would refuse it.
        _ = try ConversionRequest(action: .encrypt, source: inputs[0].source,
                                  destination: destinationParent.appendingPathComponent("preflight-probe.BIN.ENC"),
                                  keyFile: keyFile, contentID: contentID,
                                  discNumber: 1, logicalName: "ISO.BIN.ENC").arguments()

        let ready = destinationParent.appendingPathComponent(readyFolderName)
        let imageFolder = ftpLayout ? ready.appendingPathComponent("dev_hdd0/PS2ISO") : ready
        try requireDirectoryOrAbsent(ready)
        if ftpLayout {
            try requireDirectoryOrAbsent(ready.appendingPathComponent("dev_hdd0"))
            try requireDirectoryOrAbsent(imageFolder)
        }
        let limits = try DestinationCheck.limits(for: destinationParent)
        var seenSources = Set<String>(), seenFolders = Set<String>(), seenGameIDs = Set<String>()
        var planned = [HENPreparedItem]()
        var notes = [String]()
        for entry in inputs {
            try cancelled()
            let source = entry.source.standardizedFileURL
            guard source.isFileURL, source.pathExtension.lowercased() == "iso" else {
                throw ConversionFailure(message: "\(entry.source.lastPathComponent): choose a PS2 .iso image for this preset.")
            }
            var sourceInfo = stat()
            guard lstat(source.path, &sourceInfo) == 0,
                  (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
                throw ConversionFailure(message: "\(source.lastPathComponent): the source must be a regular ISO file, not a link or folder.")
            }
            guard seenSources.insert(source.path).inserted else {
                throw ConversionFailure(message: "\(source.lastPathComponent) appears twice in this batch.")
            }
            let inspected = try DiscInspector.inspect(source)
            guard inspected.isSupported, let id = inspected.gameID,
                  GameProject.validGameID(id) else {
                throw ConversionFailure(message: "\(source.lastPathComponent) has no readable PS2 SYSTEM.CNF game ID. Check the ISO before conversion.")
            }
            guard seenGameIDs.insert(id).inserted else {
                throw ConversionFailure(message: "\(source.lastPathComponent) reports the same game ID as another ISO in this batch (\(displayGameID(id))). Remove the duplicate so each game is exported once.")
            }
            let name = "\(safeStem(source)) [\(displayGameID(id))]"
            let folder = imageFolder.appendingPathComponent(name)
            let imageName = name + ".BIN.ENC"
            guard seenFolders.insert(folder.path.lowercased()).inserted else {
                throw ConversionFailure(message: "Two ISOs would create the same output folder (\(name)). Give them distinct filenames before batching.")
            }
            let sourceHash = try FileDigest.sha256(source, cancelled: cancelled)
            let candidate = HENPreparedItem(id: entry.id, source: source, gameID: id,
                                            sourceBytes: inspected.byteCount, sourceSHA256: sourceHash, folder: folder,
                                            imageName: imageName, config: entry.config,
                                            configSHA256: nil, configBytes: nil)
            // Both the image and its CONFIG sidecar must be storable, since
            // they are published as one folder.
            try DestinationCheck.validate(path: candidate.output,
                                          requiredBytes: candidate.estimatedOutputBytes,
                                          limits: limits)
            try DestinationCheck.validate(path: folder.appendingPathComponent(imageName + ".CONFIG"),
                                          requiredBytes: 0, limits: limits)
            guard !fm.fileExists(atPath: folder.path) else {
                throw ConversionFailure(message: "Output already exists for \(source.lastPathComponent): \(folder.path). Existing work is never replaced.")
            }
            var bytes: Data?, fingerprint: String?
            if let config = entry.config {
                do { bytes = try configBytes(config) }
                catch {
                    let reason = (error as? ConversionFailure)?.message ?? error.localizedDescription
                    throw ConversionFailure(message: "\(source.lastPathComponent) CONFIG: \(reason)")
                }
                fingerprint = FileDigest.sha256(data: bytes!)
                if let chosen = entry.configSHA256, fingerprint != chosen {
                    throw ConversionFailure(message: "\(source.lastPathComponent) CONFIG changed after selection. Choose it again.")
                }
            }
            planned.append(HENPreparedItem(id: entry.id, source: source, gameID: id,
                                           sourceBytes: inspected.byteCount, sourceSHA256: sourceHash, folder: folder,
                                           imageName: imageName, config: entry.config,
                                           configSHA256: fingerprint, configBytes: bytes))
        }
        let needed = requiredBytes(for: planned)
        try checkCapacity(requiredBytes: needed, freeBytes: limits.freeBytes)
        if ftpLayout {
            notes.append("Folders are nested to mirror \(planPathNote). Copy the contents of each game folder into /dev_hdd0/PS2ISO on the console. This app does not transfer files and does not store FTP credentials.")
        } else {
            notes.append("Copy each game folder's .BIN.ENC (and its .CONFIG, if present) into /dev_hdd0/PS2ISO on the console, then launch it with the PS2 Classics Launcher. Raw .iso files are CFW-only.")
        }
        if !contentID.isEmpty {
            notes.append("The encrypted header binds the content ID \(contentID); it must match the console's support files.")
        }
        return HENBatchPlan(items: planned, readyFolder: ready, imageFolder: imageFolder,
                            keyFile: keyFile, keySHA256: keyHash, contentID: contentID,
                            folderLayout: ftpLayout, requiredBytes: needed,
                            freeBytes: limits.freeBytes, fileSystem: limits.fileSystem,
                            notes: notes)
    }

    private static var planPathNote: String { "Ready for Super Slim/dev_hdd0/PS2ISO" }

    /// A klicensee is exactly 16 binary bytes. A RAP/RIF is a different,
    /// non-matching artefact, so it is rejected by name as well as by length.
    public static func validateKey(_ keyFile: URL) throws -> Data {
        guard !["rap", "rif"].contains(keyFile.pathExtension.lowercased()) else {
            throw ConversionFailure(message: "A RAP/RIF is not a klicensee. Choose the matching 16-byte binary key.")
        }
        var info = stat()
        guard lstat(keyFile.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw ConversionFailure(message: "The klicensee must be a regular file, not a link or folder: \(keyFile.lastPathComponent)")
        }
        let key = try FileDigest.small(keyFile, maximum: 16)
        guard key.count == 16 else {
            throw ConversionFailure(message: "The klicensee must contain exactly 16 bytes; \(keyFile.lastPathComponent) has \(key.count).")
        }
        return key
    }

    // MARK: - Export

    private static func createDirectory(_ url: URL) throws {
        try requireDirectoryOrAbsent(url)
        if !fm.fileExists(atPath: url.path) {
            guard mkdir(url.path, 0o700) == 0 else {
                throw ConversionFailure(message: "Cannot create output folder: \(url.path)")
            }
        }
    }

    /// Converts one job in a private folder on the destination volume. Only a
    /// fully verified image and its CONFIG are exposed by an exclusive atomic
    /// folder rename, so no apparently complete game folder can survive a
    /// failure or a cancel. Callers invoke this sequentially.
    @discardableResult
    public static func export(_ item: HENPreparedItem, plan: HENBatchPlan,
                              helper: URL, runner: ConversionRunner,
                              progress: @escaping @Sendable (ConversionProgress) -> Void) throws -> URL {
        try runner.checkCancellation()
        try createDirectory(plan.readyFolder)
        if plan.folderLayout {
            try createDirectory(plan.readyFolder.appendingPathComponent("dev_hdd0"))
            try createDirectory(plan.imageFolder)
        }
        try DestinationCheck.probeWritable(folder: plan.imageFolder)
        guard !fm.fileExists(atPath: item.folder.path) else {
            throw ConversionFailure(message: "Output already exists: \(item.folder.path)")
        }
        let limits = try DestinationCheck.limits(for: plan.imageFolder)
        let size = item.estimatedOutputBytes
        try checkCapacity(requiredBytes: size + workingMarginBytes, freeBytes: limits.freeBytes)
        // Re-validate every precondition the user could have invalidated while
        // the batch was queued or while earlier games were converting.
        let currentKey = try validateKey(plan.keyFile)
        guard FileDigest.sha256(data: currentKey) == plan.keySHA256 else {
            throw ConversionFailure(message: "The klicensee changed since preflight. Run Check batch again with the matching key.")
        }
        if let config = item.config, let expected = item.configSHA256 {
            guard try configFingerprint(config) == expected else {
                throw ConversionFailure(message: "The CONFIG changed since preflight: \(config.lastPathComponent). Run Check batch again.")
            }
        }
        let currentInspection = try DiscInspector.inspect(item.source)
        guard currentInspection.isSupported,
              currentInspection.byteCount == item.sourceBytes,
              currentInspection.gameID == item.gameID else {
            throw ConversionFailure(message: "The ISO changed since preflight: \(item.source.lastPathComponent). Run Check batch again.")
        }
        let sourceHash = try FileDigest.sha256(item.source, cancelled: { try runner.checkCancellation() })
        guard sourceHash == item.sourceSHA256 else {
            throw ConversionFailure(message: "The ISO bytes changed since preflight: \(item.source.lastPathComponent). Check the batch again; no output was published.")
        }
        let stage = plan.imageFolder.appendingPathComponent(".ps2-hen-" + UUID().uuidString)
        guard mkdir(stage.path, 0o700) == 0 else {
            throw ConversionFailure(message: "Cannot create a private output folder: \(stage.path)")
        }
        do {
            let stagedImage = stage.appendingPathComponent(item.imageName)
            let request = ConversionRequest(action: .encrypt, source: item.source,
                                            destination: stagedImage, keyFile: plan.keyFile,
                                            contentID: plan.contentID,
                                            discNumber: 1, logicalName: "ISO.BIN.ENC")
            try runner.run(request, helper: helper, progress: progress)
            try runner.verify(source: stagedImage, keyFile: plan.keyFile, discNumber: 1,
                              logicalName: "ISO.BIN.ENC", helper: helper, progress: progress)
            // The source is proven unchanged across the whole job, so a
            // published image always corresponds to the bytes preflight saw.
            guard try FileDigest.sha256(item.source, cancelled: { try runner.checkCancellation() }) == sourceHash else {
                throw ConversionFailure(message: "The source ISO changed during conversion; no output was published.")
            }
            guard FileDigest.sha256(data: try validateKey(plan.keyFile)) == plan.keySHA256 else {
                throw ConversionFailure(message: "The klicensee changed during conversion; no output was published.")
            }
            if let config = item.config, let expected = item.configSHA256 {
                guard try configFingerprint(config) == expected else {
                    throw ConversionFailure(message: "The CONFIG changed during conversion; no output was published.")
                }
            }
            if let bytes = item.configBytes {
                try bytes.write(to: stage.appendingPathComponent(item.imageName + ".CONFIG"),
                                options: .withoutOverwriting)
            }
            try runner.checkCancellation()
            guard renamex_np(stage.path, item.folder.path, UInt32(RENAME_EXCL)) == 0 else {
                throw ConversionFailure(message: "Could not publish the verified game folder without replacing existing work: \(item.folder.path)")
            }
            return item.folder
        } catch {
            // Never leave a staged folder that looks like finished work. If
            // the removal itself fails, say so plainly and name the path
            // instead of hiding it behind the original error.
            do { try fm.removeItem(at: stage) }
            catch {
                let original = (error as? ConversionFailure)?.message ?? error.localizedDescription
                throw ConversionFailure(message: "\(original)\n\nPrivate output cleanup also failed, so a temporary folder may remain at \(stage.path). It is not a finished game. Remove it manually.")
            }
            throw error
        }
    }
}
