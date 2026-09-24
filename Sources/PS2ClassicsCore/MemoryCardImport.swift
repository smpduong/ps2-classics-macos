// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Verified save import into a NEW card file. The source card is only ever
/// opened read-only; every change lands on a private copy that is fully
/// verified before exclusive publication, and the original is never modified.
///
/// Import source: only `.ps2save` folders this app exported (manifest
/// version 1 with per-file hashes). Anything else is refused precisely;
/// there is no arbitrary-file or merge import, and an existing save name is
/// never replaced.
///
/// What is verified before publication: the export manifest match, name
/// rules, name collisions, free-space sufficiency, per-page ECC of every
/// written page, a full re-parse (the new save byte-exact, every other save
/// digest-identical), a surgical byte diff (only intended pages differ), and
/// a helper round trip. What stays open: whether a console accepts the
/// imported card — like every other feature here, that needs hardware
/// acceptance. ECC bytes are generated per the documented Hamming algorithm
/// with a zero tail (the reference community convention, proven bit-exact in
/// `MemoryCardECCTests`); spare bytes of untouched pages pass through
/// opaquely, and untouched pages keep their bytes exactly.
public enum MemoryCardImport {
    public struct ImportedFile: Sendable, Equatable {
        public let name: String
        public let bytes: Int
        public let sha256: String
    }
    public struct Result: Sendable, Equatable {
        public let save: String
        public let files: [ImportedFile]
        public let totalBytes: Int
        public let cardSHA256: String
    }
    static let maxFiles = 256
    static let maxFileBytes = 16 * 1024 * 1024
    static let maxTotalBytes = 64 * 1024 * 1024
    static let dirMode: UInt16 = 0x8427
    static let fileMode: UInt16 = 0x8417

    private struct ExportFile {
        let name: String
        let bytes: Data
    }

    /// Japan-timezone timestamp in the card's 8-byte layout (pad, sec, min,
    /// hour, day, month, little-endian year), matching the reference format.
    static func timestamp(at date: Date = Date()) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600) ?? .current
        let parts = calendar.dateComponents([.second, .minute, .hour, .day, .month, .year], from: date)
        var out = Data(count: 8)
        out[1] = UInt8(parts.second ?? 0); out[2] = UInt8(parts.minute ?? 0)
        out[3] = UInt8(parts.hour ?? 0); out[4] = UInt8(parts.day ?? 1)
        out[5] = UInt8(parts.month ?? 1)
        let year = UInt16(parts.year ?? 2000)
        out[6] = UInt8(year & 255); out[7] = UInt8(year >> 8)
        return out
    }

    private static func checkedWrite(fd: Int32, offset: UInt64, data: Data,
                                     writtenPages: inout Set<UInt64>, stride: UInt64) throws {
        var remaining = data.count
        var position = offset
        try data.withUnsafeBytes { body in
            guard var base = body.baseAddress, !data.isEmpty else { return }
            while remaining > 0 {
                if lseek(fd, off_t(position), SEEK_SET) < 0 {
                    throw ConversionFailure(message: "The import workspace could not be written.")
                }
                let n = write(fd, base, remaining)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw ConversionFailure(message: "The import workspace could not be written.") }
                base += n; remaining -= n; position += UInt64(n)
            }
        }
        if !data.isEmpty {
            for page in (offset / stride)...((offset + UInt64(data.count) - 1) / stride) {
                writtenPages.insert(page)
            }
        }
    }

    /// Writes one full data page with freshly calculated ECC and a zero tail,
    /// and records the page for the surgical diff.
    private static func writeDataPage(fd: Int32, geometry: MemoryCardSaves.Geometry, page: UInt64,
                                      data: Data, writtenPages: inout Set<UInt64>) throws {
        let data = Data(data)
        guard data.count == Int(geometry.pageLength) else {
            throw ConversionFailure(message: "Internal import error: short page write.")
        }
        let stride = geometry.pageStride
        try checkedWrite(fd: fd, offset: page * stride, data: data, writtenPages: &writtenPages, stride: stride)
        var spare = MemoryCardECC.calculatePage(data)
        spare.append(Data(count: 16 - spare.count))
        try checkedWrite(fd: fd, offset: page * stride + UInt64(geometry.pageLength),
                         data: spare, writtenPages: &writtenPages, stride: stride)
    }

    /// Writes one allocatable cluster (relative index) with fresh ECC.
    /// The buffer is copied to zero-based indexing first: callers pass
    /// slices, and integer subscripts address the entry, not the source.
    private static func writeRelativeCluster(fd: Int32, geometry: MemoryCardSaves.Geometry, relative: UInt64,
                                             data: Data, writtenPages: inout Set<UInt64>) throws {
        let data = Data(data)
        guard data.count == Int(geometry.clusterBytes) else {
            throw ConversionFailure(message: "Internal import error: short cluster write.")
        }
        for i in 0..<geometry.pagesPerCluster {
            let start = Int(i * geometry.pageLength)
            try writeDataPage(fd: fd, geometry: geometry,
                              page: (geometry.allocOffset + relative) * geometry.pagesPerCluster + i,
                              data: data[start..<start + Int(geometry.pageLength)],
                              writtenPages: &writtenPages)
        }
    }

    /// Writes one cluster by absolute cluster number (for FAT clusters).
    /// Copies to zero-based indexing first, like writeRelativeCluster.
    private static func writeAbsoluteCluster(fd: Int32, geometry: MemoryCardSaves.Geometry, absolute: UInt64,
                                             data: Data, writtenPages: inout Set<UInt64>) throws {
        let data = Data(data)
        guard data.count == Int(geometry.clusterBytes) else {
            throw ConversionFailure(message: "Internal import error: short cluster write.")
        }
        for i in 0..<geometry.pagesPerCluster {
            let start = Int(i * geometry.pageLength)
            try writeDataPage(fd: fd, geometry: geometry, page: absolute * geometry.pagesPerCluster + i,
                              data: data[start..<start + Int(geometry.pageLength)],
                              writtenPages: &writtenPages)
        }
    }

    private static func direntBytes(mode: UInt16, length: UInt32, cluster: UInt32, dirEntry: UInt32,
                                    now: Data, name: String) -> Data {
        var entry = Data(count: 512)
        entry[0] = UInt8(mode & 255); entry[1] = UInt8(mode >> 8)
        for (offset, value) in [(4, length), (0x10, cluster), (0x14, dirEntry)] {
            entry[offset] = UInt8(value & 255); entry[offset + 1] = UInt8((value >> 8) & 255)
            entry[offset + 2] = UInt8((value >> 16) & 255); entry[offset + 3] = UInt8((value >> 24) & 255)
        }
        entry.replaceSubrange(0x08..<0x10, with: now)
        entry.replaceSubrange(0x18..<0x20, with: now)
        let nameBytes = Data(name.utf8)
        entry.replaceSubrange(0x40..<0x40 + nameBytes.count, with: nameBytes)
        return entry
    }

    /// Bounded streaming byte comparison. Proves two files hold exactly the
    /// same bytes with O(chunk) memory, checks lengths up front, propagates
    /// every open/read error, and honors cancellation. Two failed reads never
    /// compare equal: any failure throws instead of returning a verdict.
    static func requireIdenticalFiles(_ first: URL, _ second: URL, context: String,
                                      runner: ConversionRunner) throws {
        func openRead(_ url: URL) throws -> Int32 {
            guard url.isFileURL else {
                throw ConversionFailure(message: "\(context): comparison file is not a local file.")
            }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                throw ConversionFailure(message: "\(context): comparison file cannot be opened.")
            }
            return fd
        }
        let a = try openRead(first)
        defer { close(a) }
        let b = try openRead(second)
        defer { close(b) }
        var sa = stat(), sb = stat()
        guard fstat(a, &sa) == 0, fstat(b, &sb) == 0,
              (sa.st_mode & S_IFMT) == S_IFREG, (sb.st_mode & S_IFMT) == S_IFREG else {
            throw ConversionFailure(message: "\(context): comparison files are not regular files.")
        }
        guard sa.st_size > 0, sa.st_size == sb.st_size else {
            throw ConversionFailure(message: "\(context): files differ in length.")
        }
        var remaining = UInt64(sa.st_size)
        var chunkA = [UInt8](repeating: 0, count: 1048576)
        var chunkB = [UInt8](repeating: 0, count: 1048576)
        while remaining > 0 {
            try runner.checkCancellation()
            let count = Int(min(remaining, 1048576))
            let gotA: Int = chunkA.withUnsafeMutableBytes {
                readExactly(fd: a, $0.baseAddress!, count)
            }
            let gotB: Int = chunkB.withUnsafeMutableBytes {
                readExactly(fd: b, $0.baseAddress!, count)
            }
            // Short reads (truncation mid-compare, source change) fail rather
            // than comparing a prefix as equal.
            guard gotA == count, gotB == count,
                  chunkA.prefix(count) == chunkB.prefix(count) else {
                throw ConversionFailure(message: "\(context): files differ in content.")
            }
            remaining -= UInt64(count)
        }
    }

    /// Reads up to `count` bytes unless EOF/error intervenes; returns what
    /// was read. Retries on interrupt; any other shortfall is the caller's
    /// mismatch to report, never silent agreement.
    private static func readExactly(fd: Int32, _ base: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var total = 0
        var pointer = base
        while total < count {
            let n = read(fd, pointer, count - total)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            total += n
            pointer += n
        }
        return total
    }

    /// Test seams (internal, reset by tests). `testHookAfterWrites` runs after
    /// the import writes are flushed but before any verification, so a test
    /// can corrupt an unrelated page through the live fd; the pre-write
    /// baseline diff must then refuse. `testHookAfterPublish` runs after
    /// exclusive publication but before the final cancellation/digest, so a
    /// test can cancel during final hashing.
    static var testHookAfterWrites: ((Int32, MemoryCardSaves.Geometry, UInt64) -> Void)?
    static var testHookAfterPublish: (() throws -> Void)?
    /// Forces post-publication identity capture to behave as if lstat failed,
    /// exercising the fail-safe path (never delete without proven ownership).
    static var testFailIdentityCapture = false
    /// Runs after an owned output is moved to its private quarantine name but
    /// before the quarantined identity is verified, so a test can plant a
    /// replacement at the destination inside the old check-then-delete window.
    static var testHookAfterQuarantineMove: (() -> Void)?

    /// Pages covering one allocatable (relative) cluster.
    static func pagesForRelativeCluster(_ relative: UInt64, geometry: MemoryCardSaves.Geometry) -> [UInt64] {
        (0..<geometry.pagesPerCluster).map { (geometry.allocOffset + relative) * geometry.pagesPerCluster + $0 }
    }

    /// Pages covering one absolute cluster (for FAT clusters).
    static func pagesForAbsoluteCluster(_ absolute: UInt64, geometry: MemoryCardSaves.Geometry) -> [UInt64] {
        (0..<geometry.pagesPerCluster).map { absolute * geometry.pagesPerCluster + $0 }
    }

    /// Surgical diff against an immutable pre-write baseline. Every byte that
    /// differs between the baseline file and the live fd must sit on a page in
    /// `allowed` (derived from the planned allocation, not from what writes
    /// happened to touch). Streams in bounded cancellable chunks with strict
    /// length/read handling; any failure throws instead of passing.
    static func verifySurgicalDiff(baseline: URL, liveFD: Int32, size: UInt64,
                                   geometry: MemoryCardSaves.Geometry, allowed: Set<UInt64>,
                                   runner: ConversionRunner) throws {
        guard baseline.isFileURL else {
            throw ConversionFailure(message: "The import baseline is not a local file. Nothing was published.")
        }
        let baseFD = open(baseline.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard baseFD >= 0 else {
            throw ConversionFailure(message: "The import baseline could not be read. Nothing was published.")
        }
        defer { close(baseFD) }
        var st = stat()
        guard fstat(baseFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0, UInt64(st.st_size) == size else {
            throw ConversionFailure(message: "The import baseline changed or is not a regular file. Nothing was published.")
        }
        let stride = geometry.pageStride
        let chunk: UInt64 = 1024 * 1024
        var offset: UInt64 = 0
        while offset < size {
            try runner.checkCancellation()
            let count = Int(min(chunk, size - offset))
            guard lseek(liveFD, off_t(offset), SEEK_SET) >= 0,
                  lseek(baseFD, off_t(offset), SEEK_SET) >= 0 else {
                throw ConversionFailure(message: "The imported copy could not be re-read. Nothing was published.")
            }
            var liveBytes = [UInt8](repeating: 0, count: count)
            var baseBytes = [UInt8](repeating: 0, count: count)
            let gotLive = liveBytes.withUnsafeMutableBytes { readExactly(fd: liveFD, $0.baseAddress!, count) }
            let gotBase = baseBytes.withUnsafeMutableBytes { readExactly(fd: baseFD, $0.baseAddress!, count) }
            guard gotLive == count, gotBase == count else {
                throw ConversionFailure(message: "The imported copy could not be re-read. Nothing was published.")
            }
            if liveBytes != baseBytes {
                var page = offset / stride
                let last = (offset + UInt64(count) - 1) / stride
                while page <= last {
                    let start = Int(page * stride < offset ? 0 : page * stride - offset)
                    let end = min(Int((page + 1) * stride - offset), count)
                    if liveBytes[start..<end] != baseBytes[start..<end] {
                        guard allowed.contains(page) else {
                            throw ConversionFailure(message: "The import touched an unexpected page. Nothing was published.")
                        }
                    }
                    page += 1
                }
            }
            offset += UInt64(count)
        }
    }

    /// Removes an exclusively published output through a private quarantine
    /// directory. The destination is moved atomically into a fresh 0700
    /// directory with an unguessable name on the same filesystem; only the
    /// secured inode, verified through an open file description against
    /// `expected`, is ever deleted. A file this operation did not publish is
    /// moved back to the destination, never deleted.
    ///
    /// Threat model (same-user concurrent mutation): the single-operation slot
    /// excludes this process from racing itself, and unguessable private names
    /// exclude actors working from known paths (user file actions, sync
    /// daemons). What remains is a same-user actor that can write the
    /// destination directory AND targets the private name inside a microsecond
    /// window between verification and deletion. macOS offers no atomic
    /// identity-conditional unlink, so that residual cannot be closed in code;
    /// note such an actor can already replace the destination itself at any
    /// time, before or after this function runs, which bounds the guarantee to
    /// non-Byzantine concurrent mutators. There is deliberately no
    /// identity-less fallback: without a captured identity, ownership cannot
    /// be proven and nothing is removed.
    static func removeOwnedOutput(at destination: URL, expected: FileIdentity) throws {
        guard destination.isFileURL else {
            throw ConversionFailure(message: "The import failed after publication, and the unverified output could not be secured for removal. Check \(destination.lastPathComponent) manually.")
        }
        let quarantineDir = destination.deletingLastPathComponent()
            .appendingPathComponent(".ps2-quarantine-" + UUID().uuidString)
        guard mkdir(quarantineDir.path, 0o700) == 0 else {
            throw ConversionFailure(message: "The import failed after publication, and the unverified output at \(destination.lastPathComponent) could not be secured for removal. Remove it manually after checking it.")
        }
        // Fixed entry name inside our own unpredictable directory: nothing
        // outside this function can address it without the directory name.
        let quarantine = quarantineDir.appendingPathComponent("output")
        guard renamex_np(destination.path, quarantine.path, UInt32(RENAME_EXCL)) == 0 else {
            let failure = errno
            try? FileManager.default.removeItem(at: quarantineDir)
            if failure == ENOENT { return } // Already gone: nothing of ours stands.
            throw ConversionFailure(message: "The import failed after publication, and the unverified output at \(destination.lastPathComponent) could not be secured for removal. Remove it manually after checking it.")
        }
        if let moveHook = testHookAfterQuarantineMove { moveHook() }
        let fd = open(quarantine.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // Unopenable (symlink, or vanished under us): never delete blindly.
            // A vanished entry reports exactly that; anything still present is
            // restored so the error cannot claim a file was preserved that is
            // not there.
            if FileIdentity.of(quarantine) == nil {
                try? FileManager.default.removeItem(at: quarantineDir)
                throw ConversionFailure(message: "The quarantined file in \(quarantineDir.lastPathComponent) vanished before it could be verified or removed. Check \(destination.lastPathComponent) manually; nothing was deleted.")
            }
            try restoreQuarantined(quarantine, in: quarantineDir, to: destination)
            return
        }
        defer { close(fd) }
        var status = stat()
        guard expected.isRegularFile, !expected.isSymbolicLink,
              fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              UInt64(bitPattern: Int64(status.st_dev)) == expected.device,
              UInt64(status.st_ino) == expected.inode else {
            try restoreQuarantined(quarantine, in: quarantineDir, to: destination)
            return
        }
        do {
            try FileManager.default.removeItem(at: quarantine)
            try FileManager.default.removeItem(at: quarantineDir)
        } catch {
            throw ConversionFailure(message: "The import failed after publication, and the unverified output secured in \(quarantineDir.lastPathComponent) could not be removed. Remove it manually after checking it.")
        }
    }

    /// Moves a quarantined file back to its destination without overwriting.
    /// A vanished entry reports exactly that; a re-occupied destination keeps
    /// the quarantined file with both locations named. Nothing is deleted.
    private static func restoreQuarantined(_ quarantine: URL, in quarantineDir: URL, to destination: URL) throws {
        guard renamex_np(quarantine.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if FileIdentity.of(quarantine) == nil {
                try? FileManager.default.removeItem(at: quarantineDir)
                throw ConversionFailure(message: "The quarantined file in \(quarantineDir.lastPathComponent) vanished during recovery. Check \(destination.lastPathComponent) manually; nothing was deleted.")
            }
            throw ConversionFailure(message: "A file this operation did not publish was preserved in \(quarantineDir.lastPathComponent) because \(destination.lastPathComponent) is now occupied. Review both manually before removing anything.")
        }
        // Best-effort removal of our own now-empty directory; the file it held
        // is already restored, so a failure here strands only an empty folder.
        try? FileManager.default.removeItem(at: quarantineDir)
    }

    /// Verifies an already-published encrypted file by decrypting it aside,
    /// checking the imported save's hashes AND comparing the decrypted bytes
    /// byte-for-byte with the verified raw card. Anything that fails removes
    /// only the proven-owned published file via the private-quarantine
    /// protocol (a file this operation did not publish is moved back, never
    /// deleted; see the residual note on removeOwnedOutput), so an unverified
    /// result never stands as output. `expectedIdentity` is required: without
    /// it nothing is removed.
    static func verifyPublishedFile(at destination: URL, save: String, expectedSHA256s: [String],
                                    helper: URL, runner: ConversionRunner, workspace: URL,
                                    raw: URL, expectedIdentity: FileIdentity) throws {
        typealias S = MemoryCardSaves
        do {
            let check = workspace.appendingPathComponent("published-check")
            if FileManager.default.fileExists(atPath: check.path) {
                try FileManager.default.removeItem(at: check)
            }
            try runner.run(arguments: ["vmc-decrypt", destination.path, check.path], helper: helper, progress: { _ in })
            try runner.checkCancellation()
            let (checkFD, checkSize) = try S.openCard(check)
            defer { close(checkFD) }
            let published = try S.scan(fd: checkFD, size: checkSize, runner: runner, progress: { _ in })
            guard published.first(where: { $0.name == save })?.files.map(\.sha256).sorted() ==
                    expectedSHA256s.sorted() else {
                throw ConversionFailure(message: "The published file did not verify.")
            }
            // Full-card check: altered bytes in another save or in metadata
            // escape the save-hash comparison above, so the decrypted output
            // must also match the verified raw card byte-for-byte.
            do {
                try requireIdenticalFiles(check, raw, context: "Published-card verification", runner: runner)
            } catch {
                throw ConversionFailure(message: "The published file did not verify (\(error.localizedDescription)).")
            }
        } catch let original {
            // Only an output this operation published may be removed; a
            // concurrently replaced file is left alone. A removal failure is
            // honest in the thrown error instead of claiming nothing remains.
            do {
                try removeOwnedOutput(at: destination, expected: expectedIdentity)
            } catch let cleanupError as ConversionFailure {
                throw ConversionFailure(message: "\(original.localizedDescription) \(cleanupError.localizedDescription)")
            }
            throw original
        }
    }

    @discardableResult
    public static func importSave(_ saveDir: URL, card: URL, destination: URL, helper: URL,
                                  runner: ConversionRunner,
                                  progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) throws -> Result {
        typealias S = MemoryCardSaves
        // 1. The export package: only our own verified exports are accepted.
        guard saveDir.isFileURL, saveDir.pathExtension == "ps2save" else {
            throw ConversionFailure(message: "Choose a .ps2save folder previously exported by this app. Other folders are not accepted.")
        }
        let manifestDecoder = JSONDecoder()
        manifestDecoder.dateDecodingStrategy = .iso8601
        guard let manifestBytes = try? BoundedFile.read(saveDir.appendingPathComponent("manifest.json"), maximum: 65536),
              let manifest = try? manifestDecoder.decode(S.ExportManifest.self, from: manifestBytes) else {
            throw ConversionFailure(message: "The export folder has no readable manifest. Only verified .ps2save exports can be imported.")
        }
        guard manifest.version == 1, S.validEntryName(manifest.save) else {
            throw ConversionFailure(message: "The export manifest is unsupported or names an unusable save.")
        }
        guard manifest.files.count <= maxFiles else {
            throw ConversionFailure(message: "The export manifest lists an unsupported number of files.")
        }
        var seenNames = Set<String>(), total = 0
        var payloads = [ExportFile]()
        for file in manifest.files {
            guard S.validEntryName(file.name), !seenNames.contains(file.name) else {
                throw ConversionFailure(message: "The export manifest names an unusable or duplicated file.")
            }
            seenNames.insert(file.name)
            guard file.bytes >= 0, file.bytes <= maxFileBytes,
                  file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ConversionFailure(message: "The export manifest entry for “\(file.name)” is unsupported or damaged.")
            }
            total += file.bytes
            guard total <= maxTotalBytes else {
                throw ConversionFailure(message: "The exported save is larger than the supported import limit.")
            }
            let url = saveDir.appendingPathComponent(file.name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size == file.bytes else {
                throw ConversionFailure(message: "Exported file “\(file.name)” is missing or does not match its manifest.")
            }
            let bytes: Data = size == 0 ? Data() : try FileDigest.small(url, maximum: maxFileBytes)
            guard FileDigest.sha256(data: bytes) == file.sha256 else {
                throw ConversionFailure(message: "Exported file “\(file.name)” does not match its recorded checksum. Nothing was imported.")
            }
            payloads.append(ExportFile(name: file.name, bytes: bytes))
        }
        // 2. Destination and private workspace. The source card is never opened
        // for writing; all changes land on a staged copy.
        guard destination.isFileURL else { throw ConversionFailure(message: "Choose a local destination file.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ConversionFailure(message: "The destination already exists. Existing cards are never replaced.")
        }
        try DestinationCheck.probeWritable(folder: destination.deletingLastPathComponent())
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(".ps2-save-import-" + UUID().uuidString)
        guard mkdir(workspace.path, 0o700) == 0 else {
            throw ConversionFailure(message: "Cannot create a private import workspace.")
        }
        // Workspace disposal has one structured choke point per outcome, so a
        // cleanup result can never contradict a reported state. The body runs
        // in an immediately-executed throwing closure (surrounding indentation
        // kept): the catch combines a primary failure with a cleanup failure
        // while preserving the cause, and success disposal is explicit after
        // it. Neither path attempts removal twice.
        let result: Result
        do {
            result = try {
        try runner.checkCancellation()
        progress(ConversionProgress(stage: "Copying card", fraction: 0.05))
        let raw = workspace.appendingPathComponent("card.work")
        let encrypted: Bool
        if try S.readPrefix(card, count: 28) == S.magic {
            guard card.pathExtension.lowercased() == "vmc",
                  destination.pathExtension.lowercased() == "vmc" else {
                throw ConversionFailure(message: "An unencrypted card imports into a new .VMC file. Choose a matching destination name.")
            }
            try FileManager.default.copyItem(at: card, to: raw)
            encrypted = false
        } else {
            guard card.pathExtension.lowercased() == "vme",
                  destination.pathExtension.lowercased() == "vme" else {
                throw ConversionFailure(message: "An encrypted card imports into a new .VME file. Choose a matching destination name.")
            }
            try runner.run(arguments: ["vmc-decrypt", card.path, raw.path], helper: helper, progress: progress)
            encrypted = true
        }
        try runner.checkCancellation()
        let fd = open(raw.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ConversionFailure(message: "Cannot stage the card copy.") }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size > 0 else {
            throw ConversionFailure(message: "Cannot stage the card copy.")
        }
        let size = UInt64(status.st_size)
        // The workspace temporarily holds the staged copy plus an immutable
        // pre-write baseline, verification and round-trip files; refuse early
        // rather than failing mid-write. Encrypted imports additionally decrypt
        // the published file aside, so they reserve one more card size.
        let workspaceFree = (try? FileManager.default.attributesOfFileSystem(forPath: workspace.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        let multiplier: UInt64 = encrypted ? 5 : 4
        let (needSpace, overflow) = size.multipliedReportingOverflow(by: multiplier)
        guard !overflow, workspaceFree > needSpace + 64 * 1024 * 1024 else {
            throw ConversionFailure(message: "Not enough free space for the import workspace (staged copy, baseline, verification and round trip). Free space first.")
        }
        // Immutable pre-write baseline for the surgical diff, captured before
        // any byte is written, for both raw (.VMC) and decrypted (.VME) inputs.
        // The final card is compared against this file — never against a copy
        // of itself — so stray writes cannot hide by copying the result.
        let baselineURL = workspace.appendingPathComponent("baseline.copy")
        do {
            try FileManager.default.copyItem(at: raw, to: baselineURL)
        } catch {
            throw ConversionFailure(message: "Cannot stage the import baseline. Free space first.")
        }
        // 3. Baseline inventory of the copy (identical bytes to the source).
        let geometry = try S.readGeometry(fd: fd, size: size)
        // ECC is defined per 512-byte page data area; other geometries stay
        // on the read-only paths (browse/export) and whole-card backup.
        guard geometry.pageLength == 512 else {
            throw ConversionFailure(message: "This card uses \(geometry.pageLength)-byte pages, which individual-save import does not support. Whole-card backup remains available.")
        }
        let reader = S.Reader(fd: fd, size: size, geometry: geometry)
        let baseline = try S.scan(fd: fd, size: size, runner: runner, progress: progress)
        guard !baseline.contains(where: { $0.name == manifest.save }) else {
            throw ConversionFailure(message: "Save “\(manifest.save)” already exists on this card. Imports never replace saves.")
        }
        progress(ConversionProgress(stage: "Allocating save space", fraction: 0.4))
        // 4. Root slot: reuse a deleted entry when one exists, else append.
        let perCluster = geometry.clusterBytes / 512
        guard geometry.clusterBytes % 512 == 0, perCluster >= 1 else {
            throw ConversionFailure(message: "The card geometry cannot hold directory entries. The filesystem is damaged.")
        }
        let rootCount = try S.rootEntryCount(reader, runner: runner)
        let rootChain = try reader.chainClusters(first: 0, label: "Root directory", runner: runner)
        // listDirectory enforces the count range and link entries; direct
        // indexing here would trap on a damaged zero-length root.
        let rootEntries = try S.listDirectory(reader, first: 0, count: rootCount,
                                              label: "Root directory", runner: runner)
        let slot: Int
        let newRootCount: UInt32
        if let reused = rootEntries[2...].firstIndex(where: { $0.mode & S.existsFlag == 0 }) {
            slot = reused
            newRootCount = rootCount
        } else {
            slot = rootEntries.count
            newRootCount = rootCount + 1
            guard UInt64(newRootCount) <= S.maximumDirEntries else {
                throw ConversionFailure(message: "The root directory is at its supported limit.")
            }
        }
        let rootCapacity = UInt64(rootChain.count) * perCluster
        let rootExtend = UInt64(newRootCount) > rootCapacity
        if rootExtend {
            guard UInt64(newRootCount) <= rootCapacity + perCluster else {
                throw ConversionFailure(message: "The root directory cannot grow by one cluster. The filesystem is damaged.")
            }
        }
        // 5. Allocate: file data, the save directory, and possibly one root
        // cluster. Strict first-fit ascending over truly free (zero) entries.
        // Empty files take no clusters and keep the LAST marker.
        let fileNeeds = payloads.map { $0.bytes.isEmpty ? 0 : max(1, ($0.bytes.count + Int(geometry.clusterBytes) - 1) / Int(geometry.clusterBytes)) }
        let dirNeed = max(1, (2 + payloads.count + Int(perCluster) - 1) / Int(perCluster))
        let needTotal = fileNeeds.reduce(0, +) + dirNeed + (rootExtend ? 1 : 0)
        let fat = try reader.allFATEntries(runner: runner)
        for (i, value) in fat.enumerated() where value != 0 && value & S.used == 0 {
            throw ConversionFailure(message: "FAT entry \(i) is marked free but holds data. The filesystem is damaged; use whole-card backup.")
        }
        var free = fat.indices.filter { fat[$0] == 0 }
        guard free.count >= needTotal else {
            throw ConversionFailure(message: "The card has \(free.count) free clusters but this save needs \(needTotal). Free space first.")
        }
        var taken = [UInt64]()
        for _ in 0..<needTotal { taken.append(UInt64(free.removeFirst())) }
        var fileChains = [[UInt64]](), cursor = 0
        for need in fileNeeds {
            if need == 0 {
                fileChains.append([])
            } else {
                fileChains.append(Array(taken[cursor..<cursor + need])); cursor += need
            }
        }
        let dirChain = Array(taken[cursor..<cursor + dirNeed]); cursor += dirNeed
        let rootExtra: [UInt64] = rootExtend ? [taken[cursor]] : []
        // Allowed pages for the surgical diff, derived from the planned
        // allocation and metadata changes — not from what writes happen to
        // touch. A stray write elsewhere cannot whitelist itself.
        var allowedPages = Set<UInt64>()
        for rel in taken {
            for page in pagesForRelativeCluster(rel, geometry: geometry) { allowedPages.insert(page) }
        }
        for rel in rootChain {
            for page in pagesForRelativeCluster(rel, geometry: geometry) { allowedPages.insert(page) }
        }
        do {
            var fatAbsolutes = Set<UInt32>()
            for rel in taken {
                fatAbsolutes.insert(try reader.fatEntryLocation(rel).fatCluster)
            }
            if rootExtend, let previous = rootChain.last {
                fatAbsolutes.insert(try reader.fatEntryLocation(previous).fatCluster)
            }
            for absolute in fatAbsolutes {
                for page in pagesForAbsoluteCluster(UInt64(absolute), geometry: geometry) { allowedPages.insert(page) }
            }
        } catch {
            throw ConversionFailure(message: "The card's FAT index is damaged or points outside the file. Nothing was published.")
        }
        try runner.checkCancellation()
        progress(ConversionProgress(stage: "Writing save files", fraction: 0.55))
        // 6. Writes. Every touched page gets fresh ECC plus a zero tail and
        // is recorded for the surgical diff.
        var writtenPages = Set<UInt64>()
        for (payload, chain) in zip(payloads, fileChains) {
            var blob = payload.bytes
            blob.append(Data(count: chain.count * Int(geometry.clusterBytes) - blob.count))
            for (rel, i) in zip(chain, 0..<chain.count) {
                let start = i * Int(geometry.clusterBytes)
                try writeRelativeCluster(fd: fd, geometry: geometry, relative: rel,
                                         data: blob[start..<start + Int(geometry.clusterBytes)],
                                         writtenPages: &writtenPages)
            }
        }
        let now = timestamp()
        var dirBlob = Data()
        // The "." entry links back to the parent: the root's first cluster
        // (always relative 0, enforced at parse) and this save's index in
        // it. This matches the reference layout; readers must not rely on it
        // but writers must set it.
        dirBlob.append(direntBytes(mode: dirMode, length: 0, cluster: 0, dirEntry: UInt32(slot),
                                   now: now, name: "."))
        dirBlob.append(direntBytes(mode: dirMode, length: 0, cluster: 0, dirEntry: 0, now: now, name: ".."))
        for (payload, chain) in zip(payloads, fileChains) {
            dirBlob.append(direntBytes(mode: fileMode, length: UInt32(payload.bytes.count),
                                       cluster: chain.first.map(UInt32.init) ?? S.last,
                                       dirEntry: 0, now: now, name: payload.name))
        }
        dirBlob.append(Data(count: dirChain.count * Int(geometry.clusterBytes) - dirBlob.count))
        for (rel, i) in zip(dirChain, 0..<dirChain.count) {
            let start = i * Int(geometry.clusterBytes)
            try writeRelativeCluster(fd: fd, geometry: geometry, relative: rel,
                                     data: dirBlob[start..<start + Int(geometry.clusterBytes)],
                                     writtenPages: &writtenPages)
        }
        // FAT links for the new chains.
        var fatValues = [UInt64: UInt32]()
        func link(_ chain: [UInt64]) {
            for (a, b) in zip(chain, chain.dropFirst()) { fatValues[a] = S.used | UInt32(b) }
            if let last = chain.last { fatValues[last] = S.last }
        }
        fileChains.forEach(link)
        link(dirChain)
        var fullRootChain = rootChain
        if let extra = rootExtra.first {
            guard let previous = rootChain.last else {
                throw ConversionFailure(message: "Internal import error: empty root chain.")
            }
            fatValues[previous] = S.used | UInt32(extra)
            fatValues[extra] = S.last
            fullRootChain.append(extra)
        }
        // Rewrite each touched FAT cluster once, preserving other entries.
        var fatCurrent = [UInt32: [UInt32]]()
        for (rel, _) in fatValues {
            let location = try reader.fatEntryLocation(rel)
            if fatCurrent[location.fatCluster] == nil {
                fatCurrent[location.fatCluster] = try reader.clusterWords(location.fatCluster)
            }
        }
        for (rel, value) in fatValues {
            let location = try reader.fatEntryLocation(rel)
            fatCurrent[location.fatCluster]![location.slot] = value
        }
        for (absolute, words) in fatCurrent {
            var blob = Data()
            for word in words {
                blob.append(contentsOf: [UInt8(word & 255), UInt8((word >> 8) & 255),
                                         UInt8((word >> 16) & 255), UInt8((word >> 24) & 255)])
            }
            try writeAbsoluteCluster(fd: fd, geometry: geometry, absolute: UInt64(absolute),
                                     data: blob, writtenPages: &writtenPages)
        }
        // Root records: the save entry at its slot (zero-filling a brand-new
        // extension cluster first so no stale bytes are published) and the
        // entry count.
        var rootBlobs = [UInt64: Data]()
        for cluster in fullRootChain {
            if rootExtend && cluster == fullRootChain.last {
                rootBlobs[cluster] = Data(count: Int(geometry.clusterBytes))
            } else {
                rootBlobs[cluster] = try reader.clusterData(geometry.allocOffset + cluster)
            }
        }
        func rootOffset(_ index: Int) -> (cluster: UInt64, at: Int) {
            (fullRootChain[index / Int(perCluster)], (index % Int(perCluster)) * 512)
        }
        let (slotCluster, slotAt) = rootOffset(slot)
        var slotBlob = rootBlobs[slotCluster]!
        slotBlob.replaceSubrange(slotAt..<slotAt + 512, with: direntBytes(
            mode: dirMode, length: UInt32(2 + payloads.count), cluster: UInt32(dirChain[0]),
            dirEntry: 0, now: now, name: manifest.save))
        rootBlobs[slotCluster] = slotBlob
        let (zeroCluster, zeroAt) = rootOffset(0)
        var zeroBlob = rootBlobs[zeroCluster]!
        let v = newRootCount
        zeroBlob[zeroAt + 4] = UInt8(v & 255); zeroBlob[zeroAt + 5] = UInt8((v >> 8) & 255)
        zeroBlob[zeroAt + 6] = UInt8((v >> 16) & 255); zeroBlob[zeroAt + 7] = UInt8((v >> 24) & 255)
        rootBlobs[zeroCluster] = zeroBlob
        for cluster in fullRootChain {
            let before = try reader.clusterData(geometry.allocOffset + cluster)
            let blob = rootBlobs[cluster]!
            if before != blob {
                try writeRelativeCluster(fd: fd, geometry: geometry, relative: cluster,
                                         data: blob, writtenPages: &writtenPages)
            }
        }
        guard fsync(fd) == 0 else {
            throw ConversionFailure(message: "The import workspace could not be flushed.")
        }
        // Test seam: corrupt an unrelated page through the live fd. The old
        // self-comparison (copying the result, then comparing it with itself)
        // would miss this; the pre-write baseline diff below must refuse.
        if let hook = testHookAfterWrites { hook(fd, geometry, size) }
        try runner.checkCancellation()
        progress(ConversionProgress(stage: "Verifying imported save", fraction: 0.75))
        // 7. Verify: ECC on every written page, a full re-parse, a surgical
        // diff, and a helper round trip. Any failure deletes the copy.
        let pageStride = geometry.pageStride
        for page in writtenPages {
            try runner.checkCancellation()
            guard lseek(fd, off_t(page * pageStride), SEEK_SET) >= 0 else {
                throw ConversionFailure(message: "The imported copy could not be re-read. Nothing was published.")
            }
            var dataBytes = [UInt8](repeating: 0, count: Int(geometry.pageLength))
            var spareBytes = [UInt8](repeating: 0, count: 16)
            let gotData = dataBytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            let gotSpare = spareBytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            guard gotData == Int(geometry.pageLength), gotSpare == 16,
                  MemoryCardECC.verify(data: Data(dataBytes), spare: Data(spareBytes)) else {
                throw ConversionFailure(message: "A written page failed its ECC check. Nothing was published.")
            }
        }
        let verifier = S.Reader(fd: fd, size: size, geometry: geometry)
        _ = verifier
        let after = try S.scan(fd: fd, size: size, runner: runner, progress: { _ in })
        guard let imported = after.first(where: { $0.name == manifest.save }) else {
            throw ConversionFailure(message: "The imported save did not verify. Nothing was published.")
        }
        guard imported.files.count == payloads.count else {
            throw ConversionFailure(message: "The imported save did not verify. Nothing was published.")
        }
        for (file, payload) in zip(imported.files.sorted(by: { $0.name < $1.name }),
                                    payloads.sorted(by: { $0.name < $1.name })) {
            guard file.name == payload.name, file.bytes == payload.bytes.count,
                  file.sha256 == FileDigest.sha256(data: payload.bytes) else {
                throw ConversionFailure(message: "Imported file “\(payload.name)” did not verify. Nothing was published.")
            }
        }
        for old in baseline {
            guard let current = after.first(where: { $0.name == old.name }) else {
                throw ConversionFailure(message: "An existing save disappeared during import. Nothing was published.")
            }
            guard current.files.map({ "\($0.name):\($0.sha256)" }) == old.files.map({ "\($0.name):\($0.sha256)" }) else {
                throw ConversionFailure(message: "Existing save “\(old.name)” changed during import. Nothing was published.")
            }
        }
        // Surgical diff against the immutable pre-write baseline: every
        // differing page must sit in the planned allowed set. Both sides stream
        // in bounded cancellable chunks; the baseline was captured before any
        // write, so a stray write cannot hide by copying the result.
        try verifySurgicalDiff(baseline: baselineURL, liveFD: fd, size: size,
                               geometry: geometry, allowed: allowedPages, runner: runner)
        try runner.checkCancellation()
        progress(ConversionProgress(stage: "Round-trip checking copy", fraction: 0.9))
        // The helper only handles the standard card sizes; smaller synthetic
        // fixtures verify everything else (ECC, re-parse, surgical diff).
        let helperSizes = [8, 16, 32, 64].map { UInt64($0) * 1024 * 1024 / 512 * 528 }
        if helperSizes.contains(size) {
            let roundTrip = workspace.appendingPathComponent("roundtrip")
            try runner.run(arguments: ["vmc-encrypt", raw.path, roundTrip.path],
                           helper: helper, progress: { _ in })
            let back = workspace.appendingPathComponent("roundtrip-back")
            try runner.run(arguments: ["vmc-decrypt", roundTrip.path, back.path],
                           helper: helper, progress: { _ in })
            do {
                try requireIdenticalFiles(back, raw, context: "Round-trip check", runner: runner)
            } catch {
                throw ConversionFailure(message: "The imported copy failed its round-trip check (\(error.localizedDescription)). Nothing was published.")
            }
        }
        try runner.checkCancellation()
        // 8. Exclusive publication, then verification of the published bytes.
        // A failure after publication (cancellation, digest read failure) must
        // publish nothing: only an output whose ownership is proven is removed
        // through the private quarantine directory (anything else is moved
        // back, never deleted, within the threat model stated on
        // removeOwnedOutput), and a removal failure is honest in the thrown
        // error instead of claiming nothing remains.
        var publishedIdentity: FileIdentity?
        var published = false
        var digest = ""
        do {
            if !encrypted {
                guard renamex_np(raw.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw ConversionFailure(message: "Cannot publish the import without replacing another item. Choose a new name on APFS or Mac OS Extended.")
                }
                published = true
                guard !testFailIdentityCapture, let identity = FileIdentity.of(destination) else {
                    throw ConversionFailure(message: "The import published \(destination.lastPathComponent) but ownership of the new file could not be proven. It was left in place for manual review; nothing was automatically removed.")
                }
                publishedIdentity = identity
            } else {
                try runner.run(arguments: ["vmc-encrypt", raw.path, destination.path], helper: helper, progress: progress)
                published = true
                guard !testFailIdentityCapture, let identity = FileIdentity.of(destination) else {
                    throw ConversionFailure(message: "The import published \(destination.lastPathComponent) but ownership of the new file could not be proven. It was left in place for manual review; nothing was automatically removed.")
                }
                publishedIdentity = identity
                try verifyPublishedFile(at: destination, save: manifest.save,
                                        expectedSHA256s: imported.files.map(\.sha256),
                                        helper: helper, runner: runner, workspace: workspace,
                                        raw: raw, expectedIdentity: identity)
            }
            // Test seam: a test cancels here so the final hashing fails after
            // the output already exists; cleanup must then remove only the
            // proven-owned file.
            if let hook = testHookAfterPublish { try hook() }
            try runner.checkCancellation()
            if published {
                guard let expected = publishedIdentity,
                      let current = FileIdentity.of(destination),
                      current == expected, current.isRegularFile, !current.isSymbolicLink else {
                    throw ConversionFailure(message: "The destination changed after publication. Nothing was confirmed.")
                }
            }
            digest = try FileDigest.sha256(destination, cancelled: { try runner.checkCancellation() })
            if published {
                guard let expected = publishedIdentity,
                      let current = FileIdentity.of(destination),
                      current == expected, current.isRegularFile, !current.isSymbolicLink else {
                    throw ConversionFailure(message: "The destination changed during verification. Nothing was confirmed.")
                }
            }
        } catch let original {
            if published, let identity = publishedIdentity {
                do {
                    try removeOwnedOutput(at: destination, expected: identity)
                } catch let cleanupError as ConversionFailure {
                    throw ConversionFailure(message: "\(original.localizedDescription) \(cleanupError.localizedDescription)")
                }
            }
            throw original
        }
        progress(ConversionProgress(stage: "Save import verified", fraction: 1))
        return Result(save: manifest.save,
                      files: imported.files.map { ImportedFile(name: $0.name, bytes: $0.bytes, sha256: $0.sha256) },
                      totalBytes: imported.totalBytes, cardSHA256: digest)
            }()
        } catch let primary {
            do {
                try FileManager.default.removeItem(at: workspace)
            } catch {
                throw ConversionFailure(message: "\(primary.localizedDescription) The private workspace at \(workspace.path) also could not be removed and still holds full card copies. Remove it manually.")
            }
            throw primary
        }
        // The card is verified and published at this point, so workspace
        // cleanup runs outside output-ownership handling: its failure must
        // never delete the good output. A leftover workspace still holds full
        // card copies, so failure is reported with its exact location instead
        // of claiming removal.
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch {
            throw ConversionFailure(message: "Save import verified and published to \(result.save) (card SHA-256 \(result.cardSHA256)), but the private workspace at \(workspace.path) could not be removed and still holds full card copies. Remove it manually.")
        }
        return result
    }
}
