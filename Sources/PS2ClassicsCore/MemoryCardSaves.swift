// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

/// Read-only individual-save inventory and verified export for PS2 cards.
///
/// Layout reference: Ross Ridge's public-domain "PlayStation 2 Memory Card
/// File System" description (superblock geometry, double-indirect FAT,
/// 512-byte directory entries), corroborated by the PS2 developer wiki's
/// Memory Card page. Only documented fields are trusted; everything else is
/// bounds-checked and anything out of range fails closed with a precise
/// message instead of being skipped.
///
/// - Raw VMC cards are opened read-only (`O_RDONLY | O_NOFOLLOW`) and never
///   modified; inventory hashes the source before and after.
/// - Encrypted VME cards are decrypted through the helper into a private
///   workspace first, then parsed identically.
/// - ECC spare bytes are not recomputed; framing, geometry, FAT chains and
///   entry cross-checks are. Whole-card integrity remains the job of the
///   verified backup/restore path, which round-trips through the helper.
/// - The `+16 KiB` extended card form is rejected precisely until its layout
///   is pinned; saves are never written back into a card (import stays
///   deferred — see DEFERRED_WORK.md).
public enum MemoryCardSaves {
    public struct SaveFile: Sendable, Equatable {
        public let name: String
        public let bytes: Int
        public let sha256: String
    }
    public struct Save: Sendable, Equatable {
        public let name: String
        public let files: [SaveFile]
        public let totalBytes: Int
    }
    public struct ExportManifest: Codable {
        public let version: Int
        public let save: String
        public let originalCard: String
        public let exportedAt: Date
        public let files: [File]
        public struct File: Codable { public let name: String; public let bytes: Int; public let sha256: String }
    }
    private static let maximumCardBytes = 70 * 1024 * 1024
    private static let maximumClusters: UInt64 = 262144
    private static let maximumDirEntries: UInt64 = 8192
    private static let maximumSaves = 1024
    private static let last: UInt32 = 0xFFFFFFFF
    private static let used: UInt32 = 0x80000000
    private static let directoryFlag: UInt16 = 0x20
    private static let fileFlag: UInt16 = 0x10
    private static let existsFlag: UInt16 = 0x8000
    private static let magic = Data("Sony PS2 Memory Card Format ".utf8)

    private struct Geometry {
        let pageLength: UInt64
        let pagesPerCluster: UInt64
        let clusters: UInt64
        let allocOffset: UInt64
        /// Allocatable clusters; every FAT index and chain link is below this.
        let fatCount: UInt64
        let clusterBytes: UInt64
        let ifc: [UInt32]
        var pageStride: UInt64 { pageLength + 16 }
        var capacityBytes: UInt64 { fatCount * clusterBytes }
    }

    private final class Reader {
        let fd: Int32
        let size: UInt64
        let geometry: Geometry
        /// FAT-bearing cluster contents by absolute cluster number. The whole
        /// table stays small (one 1 KiB cluster per 256 entries on cards).
        var fatCache = [UInt32: [UInt32]]()
        init(fd: Int32, size: UInt64, geometry: Geometry) { self.fd = fd; self.size = size; self.geometry = geometry }
        func read(offset: UInt64, count: Int) throws -> Data {
            guard count > 0, offset <= size, UInt64(count) <= size - offset else {
                throw ConversionFailure(message: "The card ends before its filesystem structures do. It may be truncated or damaged.")
            }
            var result = Data(); result.reserveCapacity(count)
            var remaining = count; var position = offset
            while remaining > 0 {
                if lseek(fd, off_t(position), SEEK_SET) < 0 {
                    throw ConversionFailure(message: "The card could not be read.")
                }
                var chunk = [UInt8](repeating: 0, count: min(65536, remaining))
                let got = chunk.withUnsafeMutableBytes { buffer -> Int in
                    var total = 0
                    while total < buffer.count {
                        let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                        if n < 0, errno == EINTR { continue }
                        guard n > 0 else { break }
                        total += n
                    }
                    return total
                }
                guard got > 0 else {
                    throw ConversionFailure(message: "The card changed or became unreadable while being listed.")
                }
                result.append(contentsOf: chunk.prefix(got)); remaining -= got; position += UInt64(got)
            }
            return result
        }
        func pageData(_ page: UInt64) throws -> Data {
            let (offset, overflow) = page.multipliedReportingOverflow(by: geometry.pageStride)
            guard !overflow, offset <= size, geometry.pageLength <= size - offset else {
                throw ConversionFailure(message: "A card reference points outside the file. The filesystem is damaged.")
            }
            return try read(offset: offset, count: Int(geometry.pageLength))
        }
        func clusterData(_ absolute: UInt64) throws -> Data {
            guard absolute < geometry.clusters else {
                throw ConversionFailure(message: "A card reference points outside the file. The filesystem is damaged.")
            }
            var result = Data(); result.reserveCapacity(Int(geometry.clusterBytes))
            let (firstPage, overflow) = absolute.multipliedReportingOverflow(by: geometry.pagesPerCluster)
            guard !overflow else {
                throw ConversionFailure(message: "A card reference points outside the file. The filesystem is damaged.")
            }
            for i in 0..<geometry.pagesPerCluster {
                result.append(try pageData(firstPage + i))
            }
            return result
        }
        func clusterWords(_ absolute: UInt32) throws -> [UInt32] {
            if let cached = fatCache[absolute] { return cached }
            let blob = try clusterData(UInt64(absolute))
            let count = Int(geometry.clusterBytes / 4)
            guard blob.count == count * 4 else {
                throw ConversionFailure(message: "The card's FAT index is damaged or points outside the file.")
            }
            var words = [UInt32](); words.reserveCapacity(count)
            for i in 0..<count {
                let base = i * 4
                words.append(UInt32(blob[base]) | UInt32(blob[base+1]) << 8 | UInt32(blob[base+2]) << 16 | UInt32(blob[base+3]) << 24)
            }
            fatCache[absolute] = words
            return words
        }
        func fatEntry(_ relative: UInt64, runner: ConversionRunner) throws -> UInt32 {
            // Double-indirect indexing per the reference: each FAT cluster
            // holds clusterBytes/4 entries; each indirect cluster names up to
            // 256 FAT clusters; ifc_list names up to 32 indirect clusters.
            let perFat = geometry.clusterBytes / 4
            guard perFat >= 1, relative < geometry.fatCount else {
                throw ConversionFailure(message: "A file chain leaves the allocation area. The filesystem is damaged.")
            }
            try runner.checkCancellation()
            let fatClusterIndex = relative / perFat
            let indirectIndex = fatClusterIndex / 256
            let indirectSlot = fatClusterIndex % 256
            guard indirectIndex < 32 else {
                throw ConversionFailure(message: "A file chain leaves the allocation area. The filesystem is damaged.")
            }
            let indirectCluster = geometry.ifc[Int(indirectIndex)]
            guard indirectCluster != MemoryCardSaves.last, UInt64(indirectCluster) < geometry.clusters else {
                throw ConversionFailure(message: "The card's FAT index is damaged or points outside the file.")
            }
            let pointers = try clusterWords(indirectCluster)
            guard indirectSlot < pointers.count else {
                throw ConversionFailure(message: "The card's FAT index is damaged or points outside the file.")
            }
            let fatCluster = pointers[Int(indirectSlot)]
            guard fatCluster != MemoryCardSaves.last, UInt64(fatCluster) < geometry.clusters else {
                throw ConversionFailure(message: "The card's FAT index is damaged or points outside the file.")
            }
            let entries = try clusterWords(fatCluster)
            guard relative % perFat < UInt64(entries.count) else {
                throw ConversionFailure(message: "The card's FAT index is damaged or points outside the file.")
            }
            return entries[Int(relative % perFat)]
        }
        /// Exactly `needed` bytes from a cluster chain, walked with cycle and
        /// range checks. The whole chain is validated to a clean terminator
        /// (so a corrupt link past the needed bytes still fails), while only
        /// `needed` bytes are retained. `needed` itself is capped at the
        /// card's allocatable capacity, so a wild length field fails before
        /// anything large is read.
        func chainData(first: UInt32, needed: UInt64, label: String, runner: ConversionRunner) throws -> Data {
            guard needed <= geometry.capacityBytes else {
                throw ConversionFailure(message: "\(label) claims more bytes than the card can hold. The filesystem is damaged.")
            }
            var result = Data()
            var seen = Set<UInt64>()
            var current = UInt64(first)
            var steps: UInt64 = 0
            while true {
                guard !seen.contains(current), current < geometry.fatCount, steps < geometry.fatCount else {
                    throw ConversionFailure(message: "\(label) has a cyclic or out-of-range cluster chain. The filesystem is damaged.")
                }
                seen.insert(current); steps += 1
                try runner.checkCancellation()
                let data = try clusterData(geometry.allocOffset + current)
                if UInt64(result.count) < needed {
                    result.append(contentsOf: data.prefix(Int(needed - UInt64(result.count))))
                }
                let entry = try fatEntry(current, runner: runner)
                if entry == MemoryCardSaves.last { break }
                guard entry & MemoryCardSaves.used != 0 else {
                    throw ConversionFailure(message: "\(label) links through a free cluster. The filesystem is damaged.")
                }
                current = UInt64(entry & 0x7FFFFFFF)
            }
            guard UInt64(result.count) >= needed else {
                throw ConversionFailure(message: "\(label) ends before its declared bytes. The filesystem is damaged.")
            }
            return result
        }
    }

    private struct Dirent {
        let mode: UInt16; let length: UInt32; let cluster: UInt32; let name: String
    }

    private static func parseDirent(_ data: Data, index: Int) throws -> Dirent {
        guard data.count == 512 else {
            throw ConversionFailure(message: "A directory record is truncated. The filesystem is damaged.")
        }
        let mode = UInt16(data[0]) | UInt16(data[1]) << 8
        let length = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        let cluster = UInt32(data[0x10]) | UInt32(data[0x11]) << 8 | UInt32(data[0x12]) << 16 | UInt32(data[0x13]) << 24
        let rawName = data[0x40..<0x60]
        guard let nul = rawName.firstIndex(of: 0) else {
            throw ConversionFailure(message: "Directory entry \(index + 1) has no terminated name. The filesystem is damaged.")
        }
        let nameData = rawName[..<nul]
        guard !nameData.isEmpty, nameData.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E && $0 != 0x2F && $0 != 0x3F && $0 != 0x2A }) else {
            throw ConversionFailure(message: "Directory entry \(index + 1) has an unusable name. The filesystem is damaged.")
        }
        return Dirent(mode: mode, length: length, cluster: cluster, name: String(decoding: nameData, as: UTF8.self))
    }

    private static func rootEntryCount(_ reader: Reader, runner: ConversionRunner) throws -> UInt32 {
        let head = try reader.chainData(first: 0, needed: 512, label: "Root directory", runner: runner)
        return try parseDirent(head, index: 0).length
    }

    private static func listDirectory(_ reader: Reader, first: UInt32, count: UInt32, label: String, runner: ConversionRunner) throws -> [Dirent] {
        guard count >= 2, UInt64(count) <= maximumDirEntries else {
            throw ConversionFailure(message: "\(label) declares \(count) entries, which is outside the supported range. The filesystem is damaged.")
        }
        guard reader.geometry.clusterBytes % 512 == 0, reader.geometry.clusterBytes >= 512 else {
            throw ConversionFailure(message: "The card geometry cannot hold directory entries. The filesystem is damaged.")
        }
        let blob = try reader.chainData(first: first, needed: UInt64(count) * 512, label: label, runner: runner)
        var entries = [Dirent]()
        for i in 0..<Int(count) {
            try runner.checkCancellation()
            // Copy to a zero-based buffer: subscripts below address the
            // entry, not the directory blob.
            entries.append(try parseDirent(Data(blob[i*512..<(i+1)*512]), index: i))
        }
        guard entries[0].name == ".", entries[1].name == ".." else {
            throw ConversionFailure(message: "\(label) does not start with its link entries. The filesystem is damaged.")
        }
        return entries
    }

    private static func readGeometry(fd: Int32, size: UInt64) throws -> Geometry {
        var probe = [UInt8](repeating: 0, count: 1040)
        guard pread(fd, &probe, probe.count, 0) == probe.count else {
            throw ConversionFailure(message: "The card is too small to hold a filesystem superblock.")
        }
        let data = Data(probe)
        guard data.prefix(28) == magic else {
            throw ConversionFailure(message: "This card is not a formatted PS2 card, or its superblock is damaged.")
        }
        func u16(_ offset: Int) -> UInt64 { UInt64(data[offset]) | UInt64(data[offset+1]) << 8 }
        func u32(_ offset: Int) -> UInt64 { u16(offset) | u16(offset+2) << 16 }
        let pageLength = u16(0x28), ppc = u16(0x2A)
        let clusters = u32(0x30), alloc = u32(0x34), root = u32(0x3C)
        guard data[0x150] == 2 else {
            throw ConversionFailure(message: "Only PS2 memory cards (type 2) are supported for save browsing.")
        }
        guard (pageLength == 512 && (ppc == 1 || ppc == 2)) || (pageLength == 1024 && ppc == 1) else {
            throw ConversionFailure(message: "The card geometry (page \(pageLength), \(ppc) pages per cluster) is outside the supported range.")
        }
        guard clusters >= 16, clusters <= maximumClusters, alloc < clusters, root == 0 else {
            throw ConversionFailure(message: "The card geometry (size or allocation fields) is inconsistent or damaged.")
        }
        let (totalPages, overflow) = clusters.multipliedReportingOverflow(by: ppc)
        guard !overflow else {
            throw ConversionFailure(message: "The card geometry (size or allocation fields) is inconsistent or damaged.")
        }
        let expected = totalPages * (pageLength + 16)
        if size != expected {
            if size == expected + 16384 {
                throw ConversionFailure(message: "This card uses the extended 16 KiB form, whose layout is not pinned yet. Use whole-card backup for it; individual-save browsing is not supported.")
            }
            throw ConversionFailure(message: "The card size does not match its declared geometry. It may be truncated or damaged.")
        }
        var ifc = [UInt32]()
        for i in 0..<32 {
            let value = UInt32(u32(0x50 + i * 4))
            if value != last, UInt64(value) >= clusters {
                throw ConversionFailure(message: "The card's FAT index points outside the file. The filesystem is damaged.")
            }
            ifc.append(value)
        }
        guard ifc.contains(where: { $0 != last }) else {
            throw ConversionFailure(message: "The card names no FAT index cluster. The filesystem is damaged.")
        }
        return Geometry(pageLength: pageLength, pagesPerCluster: ppc, clusters: clusters,
                        allocOffset: alloc, fatCount: clusters - alloc,
                        clusterBytes: pageLength * ppc, ifc: ifc)
    }

    private static func scan(fd: Int32, size: UInt64, runner: ConversionRunner,
                             progress: @escaping @Sendable (ConversionProgress) -> Void) throws -> [Save] {
        let geometry = try readGeometry(fd: fd, size: size)
        let reader = Reader(fd: fd, size: size, geometry: geometry)
        progress(ConversionProgress(stage: "Reading card directory", fraction: 0.1))
        let root = try listDirectory(reader, first: 0, count: rootEntryCount(reader, runner: runner),
                                     label: "Root directory", runner: runner)
        var saves = [Save](), seenNames = Set<String>()
        for entry in root.dropFirst(2) {
            try runner.checkCancellation()
            guard entry.mode & existsFlag != 0 else { continue } // deleted entries are not saves
            guard entry.mode & directoryFlag != 0, entry.mode & fileFlag == 0 else {
                throw ConversionFailure(message: "“\(entry.name)” in the card root is not a save folder. Files directly in the root are not supported.")
            }
            guard !seenNames.contains(entry.name) else {
                throw ConversionFailure(message: "The card lists “\(entry.name)” twice. Export would be ambiguous, so browsing stops.")
            }
            seenNames.insert(entry.name)
            guard saves.count < maximumSaves else {
                throw ConversionFailure(message: "The card holds more saves than the supported limit (\(maximumSaves)).")
            }
            let label = "Save “\(entry.name)”"
            let members = try listDirectory(reader, first: entry.cluster, count: entry.length, label: label, runner: runner)
            var files = [SaveFile](), total = 0
            for member in members.dropFirst(2) {
                try runner.checkCancellation()
                guard member.mode & existsFlag != 0 else { continue }
                guard member.mode & fileFlag != 0, member.mode & directoryFlag == 0 else {
                    throw ConversionFailure(message: "\(label) contains a nested folder. Only files inside a save are supported.")
                }
                let bytes: Data
                if member.length == 0 {
                    guard member.cluster == last else {
                        throw ConversionFailure(message: "\(label) has an empty file with a stray cluster. The filesystem is damaged.")
                    }
                    bytes = Data()
                } else {
                    guard member.cluster != last else {
                        throw ConversionFailure(message: "\(label) has a file without storage. The filesystem is damaged.")
                    }
                    bytes = try reader.chainData(first: member.cluster, needed: UInt64(member.length),
                                                 label: "\(label) file “\(member.name)”", runner: runner)
                }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                files.append(SaveFile(name: member.name, bytes: bytes.count, sha256: digest))
                total += bytes.count
            }
            saves.append(Save(name: entry.name, files: files, totalBytes: total))
            progress(ConversionProgress(stage: "Reading card directory", fraction: 0.1 + 0.4 * Double(saves.count) / Double(max(root.count - 2, 1))))
        }
        progress(ConversionProgress(stage: "Save list verified", fraction: 0.5))
        return saves
    }

    private static func openCard(_ url: URL) throws -> (Int32, UInt64) {
        guard url.isFileURL else { throw ConversionFailure(message: "Choose a local memory-card file.") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ConversionFailure(message: "Cannot read the card, or it is a symbolic link.") }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size > 0, UInt64(status.st_size) <= UInt64(maximumCardBytes) else {
            close(fd)
            throw ConversionFailure(message: "Choose a regular PS2 card file up to 70 MiB.")
        }
        return (fd, UInt64(status.st_size))
    }

    private static func readPrefix(_ url: URL, count: Int) throws -> Data {
        let (fd, _) = try openCard(url)
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress!.advanced(by: got), count - got, off_t(got)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw ConversionFailure(message: "Cannot read the card, or it is a symbolic link.") }
            got += n
        }
        return Data(buffer)
    }

    private struct RawHandle { let fd: Int32; let size: UInt64 }

    private static func decrypted<T>(card: URL, helper: URL, runner: ConversionRunner,
                                     progress: @escaping @Sendable (ConversionProgress) -> Void,
                                     body: (RawHandle) throws -> T) throws -> T {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(".ps2-save-scan-" + UUID().uuidString)
        guard mkdir(workspace.path, 0o700) == 0 else {
            throw ConversionFailure(message: "Cannot create a private card-scan workspace.")
        }
        defer { try? FileManager.default.removeItem(at: workspace) }
        let raw = workspace.appendingPathComponent("card.VMC")
        try runner.run(arguments: ["vmc-decrypt", card.path, raw.path], helper: helper, progress: progress)
        try runner.checkCancellation()
        let (fd, size) = try openCard(raw)
        defer { close(fd) }
        return try body(RawHandle(fd: fd, size: size))
    }

    /// Read-only inventory. The source is hashed before and after; any change
    /// fails instead of returning a possibly torn listing.
    public static func inventory(card: URL, helper: URL, runner: ConversionRunner,
                                 progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) throws -> [Save] {
        if try readPrefix(card, count: 28) == magic {
            let before = try FileDigest.sha256(card, cancelled: { try runner.checkCancellation() })
            let (fd, size) = try openCard(card)
            defer { close(fd) }
            let saves = try scan(fd: fd, size: size, runner: runner, progress: progress)
            try runner.checkCancellation()
            guard try FileDigest.sha256(card, cancelled: { try runner.checkCancellation() }) == before else {
                throw ConversionFailure(message: "The card changed while being listed. No result is returned.")
            }
            return saves
        }
        return try decrypted(card: card, helper: helper, runner: runner, progress: progress) { raw in
            try scan(fd: raw.fd, size: raw.size, runner: runner, progress: progress)
        }
    }

    /// Verified export of one save into a new `<name>.ps2save` folder. Every
    /// file is re-read from the card and re-hashed against the inventory; the
    /// card itself is only ever opened read-only.
    @discardableResult
    public static func export(save name: String, card: URL, into parent: URL, helper: URL, runner: ConversionRunner,
                              progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) throws -> URL {
        guard parent.isFileURL else { throw ConversionFailure(message: "Choose a local destination folder.") }
        try DestinationCheck.probeWritable(folder: parent)
        let saves = try inventory(card: card, helper: helper, runner: runner, progress: progress)
        guard let save = saves.first(where: { $0.name == name }) else {
            throw ConversionFailure(message: "Save “\(name)” is not on this card.")
        }
        let directory = parent.appendingPathComponent(name + ".ps2save")
        guard mkdir(directory.path, 0o700) == 0 else {
            throw ConversionFailure(message: "The save destination already exists or cannot be created. Existing exports are never replaced.")
        }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        try runner.checkCancellation()
        if try readPrefix(card, count: 28) == magic {
            let (fd, size) = try openCard(card)
            defer { close(fd) }
            try exportFiles(save: save, fd: fd, size: size, directory: directory, runner: runner, progress: progress)
        } else {
            try decrypted(card: card, helper: helper, runner: runner, progress: progress) { raw in
                try exportFiles(save: save, fd: raw.fd, size: raw.size, directory: directory, runner: runner, progress: progress)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = ExportManifest(version: 1, save: save.name, originalCard: card.lastPathComponent,
                                      exportedAt: Date(),
                                      files: save.files.map { ExportManifest.File(name: $0.name, bytes: $0.bytes, sha256: $0.sha256) })
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try runner.checkCancellation()
        complete = true
        progress(ConversionProgress(stage: "Save export verified", fraction: 1))
        return directory
    }

    private static func exportFiles(save: Save, fd: Int32, size: UInt64, directory: URL, runner: ConversionRunner,
                                    progress: @escaping @Sendable (ConversionProgress) -> Void) throws {
        let geometry = try readGeometry(fd: fd, size: size)
        let reader = Reader(fd: fd, size: size, geometry: geometry)
        let root = try listDirectory(reader, first: 0, count: rootEntryCount(reader, runner: runner),
                                     label: "Root directory", runner: runner)
        guard let entry = root.first(where: { $0.name == save.name }) else {
            throw ConversionFailure(message: "Save “\(save.name)” is not on this card.")
        }
        let members = try listDirectory(reader, first: entry.cluster, count: entry.length, label: "Save “\(save.name)”", runner: runner)
        var done = 0
        for member in members.dropFirst(2) {
            try runner.checkCancellation()
            guard member.mode & existsFlag != 0 else { continue }
            guard let expected = save.files.first(where: { $0.name == member.name }) else {
                throw ConversionFailure(message: "Save “\(save.name)” changed during export. No result was published.")
            }
            let bytes: Data
            if member.length == 0 {
                guard member.cluster == last else {
                    throw ConversionFailure(message: "Save “\(save.name)” changed during export. No result was published.")
                }
                bytes = Data()
            } else {
                guard member.cluster != last else {
                    throw ConversionFailure(message: "Save “\(save.name)” changed during export. No result was published.")
                }
                bytes = try reader.chainData(first: member.cluster, needed: UInt64(member.length),
                                             label: "Save “\(save.name)” file “\(member.name)”", runner: runner)
            }
            guard bytes.count == expected.bytes,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected.sha256 else {
                throw ConversionFailure(message: "Save “\(save.name)” changed during export. No result was published.")
            }
            try bytes.write(to: directory.appendingPathComponent(member.name), options: .withoutOverwriting)
            done += 1
            progress(ConversionProgress(stage: "Exporting save files", fraction: 0.5 + 0.5 * Double(done) / Double(max(save.files.count, 1))))
        }
        guard done == save.files.count else {
            throw ConversionFailure(message: "Save “\(save.name)” changed during export. No result was published.")
        }
    }
}
