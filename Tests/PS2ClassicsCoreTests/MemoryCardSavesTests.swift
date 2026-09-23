// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CryptoKit
@testable import PS2ClassicsCore

/// Synthetic cards are built in-test (small 64-cluster geometry for speed,
/// plus one full 8 MiB geometry); no card binaries live in Git. Content bytes
/// are fixed so names, sizes and digests are asserted exactly.
final class MemoryCardSavesTests: XCTestCase {
    static let icon = Data(0..<100)
    static let payload = Data((0..<2500).map { UInt8(($0 * 37) % 256) })
    static let last: UInt32 = 0xFFFFFFFF
    static let used: UInt32 = 0x80000000

    struct Built {
        let data: Data
        let clusters: Int
        let alloc: Int
    }
    /// - Parameters:
    ///   - saves: ordered (save name, files) pairs; a file value of nil means
    ///     a second save is synthesized by the caller, not here.
    func build(clusters: Int = 64, alloc: Int = 10, saves: [(String, [(String, Data)])]) -> Built {
        let ppc = 2, pages = clusters * ppc
        var raw = Data(count: pages * 528)
        func write(_ bytes: Data, at offset: Int) { raw.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        func page(_ p: Int, _ data: Data) { write(data, at: p * 528) }
        func cluster(_ c: Int, _ data: Data) {
            var padded = data; padded.append(contentsOf: repeatElement(0, count: 1024 - data.count))
            page(c * ppc, padded.prefix(512)); page(c * ppc + 1, padded.suffix(512))
        }
        func u32(_ v: UInt32) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
        func dirent(mode: UInt16, length: UInt32, cluster: UInt32, name: String, dirEntry: UInt32 = 0) -> Data {
            var entry = Data(count: 512)
            entry[0] = UInt8(mode & 255); entry[1] = UInt8(mode >> 8)
            let l = u32(length); entry.replaceSubrange(4..<8, with: l)
            let c = u32(cluster); entry.replaceSubrange(0x10..<0x14, with: c)
            let d = u32(dirEntry); entry.replaceSubrange(0x14..<0x18, with: d)
            let n = Data(name.utf8); entry.replaceSubrange(0x40..<0x40 + n.count, with: n)
            return entry
        }
        let fatCount = clusters - alloc
        var fat = [UInt32](repeating: 0, count: fatCount)
        var next = 0
        func take(_ n: Int) -> [Int] {
            var out = [Int]()
            for _ in 0..<n {
                while fat[next] != 0 { next += 1 }
                out.append(next); fat[next] = Self.used; next += 1
            }
            for (a, b) in zip(out, out.dropFirst()) { fat[a] = Self.used | UInt32(b) }
            fat[out.last!] = Self.last
            return out
        }
        let per = 2 // entries per 1024-byte cluster
        // The root directory lives at relative cluster 0 (rootdir_cluster),
        // so its chain is reserved before any file or save clusters.
        let rootChain = take((2 + saves.count + per - 1) / per)
        var rootEntries = [dirent(mode: 0x8427, length: 0, cluster: 0, name: "."), dirent(mode: 0x8427, length: 0, cluster: 0, name: "..")]
        var dirBlobs = [(chain: [Int], entries: [Data])]()
        for (saveName, files) in saves {
            var entries = [dirent(mode: 0x8427, length: 0, cluster: 0, name: ".", dirEntry: UInt32(rootEntries.count)), dirent(mode: 0x8427, length: 0, cluster: 0, name: "..")]
            for (fname, fdata) in files {
                if fdata.isEmpty {
                    entries.append(dirent(mode: 0x8417, length: 0, cluster: Self.last, name: fname))
                } else {
                    let need = (fdata.count + 1023) / 1024
                    let chain = take(need)
                    var blob = fdata; blob.append(contentsOf: repeatElement(0, count: need * 1024 - fdata.count))
                    for (rel, i) in zip(chain, 0..<need) { cluster(alloc + rel, blob[i * 1024..<(i + 1) * 1024]) }
                    entries.append(dirent(mode: 0x8417, length: UInt32(fdata.count), cluster: UInt32(chain[0]), name: fname))
                }
            }
            let chain = take((entries.count + per - 1) / per)
            dirBlobs.append((chain, entries))
            rootEntries.append(dirent(mode: 0x8427, length: UInt32(entries.count), cluster: UInt32(chain[0]), name: saveName))
        }
        rootEntries[0] = dirent(mode: 0x8427, length: UInt32(rootEntries.count), cluster: 0, name: ".")
        for (rel, i) in zip(rootChain, 0..<rootChain.count) {
            var blob = Data()
            for e in rootEntries[i * per..<min((i + 1) * per, rootEntries.count)] { blob.append(e) }
            cluster(alloc + rel, blob)
        }
        for (chain, entries) in dirBlobs {
            for (rel, i) in zip(chain, 0..<chain.count) {
                var blob = Data()
                for e in entries[i * per..<min((i + 1) * per, entries.count)] { blob.append(e) }
                cluster(alloc + rel, blob)
            }
        }
        let fatClusters = (fatCount + 255) / 256
        var indirect = [UInt32](repeating: Self.last, count: 256)
        for i in 0..<fatClusters { indirect[i] = UInt32(9 + i) }
        var indirectData = Data(); for w in indirect { indirectData.append(u32(w)) }
        cluster(8, indirectData)
        var flat = fat; flat.append(contentsOf: repeatElement(0, count: fatClusters * 256 - fat.count))
        for i in 0..<fatClusters {
            var blob = Data(); for w in flat[i * 256..<(i + 1) * 256] { blob.append(u32(w)) }
            cluster(9 + i, blob)
        }
        var sb = Data(count: 512)
        sb.replaceSubrange(0..<28, with: Data("Sony PS2 Memory Card Format ".utf8))
        sb.replaceSubrange(0x1C..<0x1C + 12, with: Data([0x31, 0x2E, 0x32, 0x2E, 0x30, 0x2E, 0x30, 0, 0, 0, 0, 0]))
        func u16(_ v: Int, at offset: Int) { sb[offset] = UInt8(v & 255); sb[offset + 1] = UInt8(v >> 8) }
        func w32(_ v: Int, at offset: Int) { let d = u32(UInt32(v)); sb.replaceSubrange(offset..<offset + 4, with: d) }
        u16(512, at: 0x28); u16(2, at: 0x2A); u16(16, at: 0x2C); u16(0xFF00, at: 0x2E)
        w32(clusters, at: 0x30); w32(alloc, at: 0x34); w32(8135, at: 0x38); w32(0, at: 0x3C)
        w32(1023, at: 0x40); w32(1022, at: 0x44)
        var ifc = Data(); ifc.append(u32(8)); for _ in 1..<32 { ifc.append(u32(Self.last)) }
        sb.replaceSubrange(0x50..<0x50 + 128, with: ifc)
        var bad = Data(); for _ in 0..<32 { bad.append(u32(Self.last)) }
        sb.replaceSubrange(0xD0..<0xD0 + 128, with: bad)
        sb[0x150] = 2; sb[0x151] = 0x52
        page(0, sb)
        return Built(data: raw, clusters: clusters, alloc: alloc)
    }

    func standardSaves() -> [(String, [(String, Data)])] {
        [("BASLUS-12345GAMEDATA", [("icon.sys", Self.icon), ("data.bin", Self.payload), ("empty.txt", Data())]),
         ("BESLES-54321EMPTY", [])]
    }

    func cardURL(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("VMC")
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func helper() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PS2_TEST_HELPER"] else { throw XCTSkip("Set PS2_TEST_HELPER") }
        return URL(fileURLWithPath: path)
    }

    func testInventoryListsSavesWithExactBytesAndHashes() throws {
        let built = build(saves: standardSaves())
        let url = try cardURL(built.data)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try FileDigest.sha256(url)
        let saves = try MemoryCardSaves.inventory(card: url, helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner())
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0].name, "BASLUS-12345GAMEDATA")
        XCTAssertEqual(saves[0].files.map(\.name), ["icon.sys", "data.bin", "empty.txt"])
        XCTAssertEqual(saves[0].files.map(\.bytes), [100, 2500, 0])
        XCTAssertEqual(saves[0].files[0].sha256, FileDigest.sha256(data: Self.icon))
        XCTAssertEqual(saves[0].files[1].sha256, FileDigest.sha256(data: Self.payload))
        XCTAssertEqual(saves[0].totalBytes, 2600)
        XCTAssertEqual(saves[1].name, "BESLES-54321EMPTY")
        XCTAssertTrue(saves[1].files.isEmpty)
        XCTAssertEqual(try FileDigest.sha256(url), before)
    }

    func testFullSizeGeometryParses() throws {
        let built = build(clusters: 8192, alloc: 41, saves: standardSaves())
        XCTAssertEqual(built.data.count, 8650752)
        let url = try cardURL(built.data)
        defer { try? FileManager.default.removeItem(at: url) }
        let saves = try MemoryCardSaves.inventory(card: url, helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner())
        XCTAssertEqual(saves.map(\.name), ["BASLUS-12345GAMEDATA", "BESLES-54321EMPTY"])
        XCTAssertEqual(saves[0].files[1].sha256, FileDigest.sha256(data: Self.payload))
    }

    func testEncryptedCardInventoryAndExport() throws {
        let helper = try helper()
        let built = build(clusters: 8192, alloc: 41, saves: standardSaves())
        try temporary { root in
            let raw = root.appendingPathComponent("card.VMC"); try built.data.write(to: raw)
            let encrypted = root.appendingPathComponent("card.VME")
            try ConversionRunner().run(arguments: ["vmc-encrypt", raw.path, encrypted.path], helper: helper, progress: { _ in })
            let before = try FileDigest.sha256(encrypted)
            let saves = try MemoryCardSaves.inventory(card: encrypted, helper: helper, runner: ConversionRunner())
            XCTAssertEqual(saves.map(\.name), ["BASLUS-12345GAMEDATA", "BESLES-54321EMPTY"])
            let exported = try MemoryCardSaves.export(save: "BASLUS-12345GAMEDATA", card: encrypted, into: root, helper: helper, runner: ConversionRunner())
            XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("icon.sys")), Self.icon)
            XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("data.bin")), Self.payload)
            XCTAssertEqual(try FileDigest.sha256(encrypted), before)
        }
    }

    func testExportCopiesVerifiesAndRefusesOverwrite() throws {
        let built = build(saves: standardSaves())
        let url = try cardURL(built.data)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try FileDigest.sha256(url)
        try temporary { root in
            let exported = try MemoryCardSaves.export(save: "BASLUS-12345GAMEDATA", card: url, into: root,
                                                      helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner())
            XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("icon.sys")), Self.icon)
            XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("data.bin")), Self.payload)
            XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("empty.txt")), Data())
            let manifestData = try Data(contentsOf: exported.appendingPathComponent("manifest.json"))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(MemoryCardSaves.ExportManifest.self, from: manifestData)
            XCTAssertEqual(manifest.version, 1)
            XCTAssertEqual(manifest.save, "BASLUS-12345GAMEDATA")
            XCTAssertEqual(manifest.files.map(\.name), ["icon.sys", "data.bin", "empty.txt"])
            XCTAssertEqual(manifest.files[1].sha256, FileDigest.sha256(data: Self.payload))
            XCTAssertThrowsError(try MemoryCardSaves.export(save: "BASLUS-12345GAMEDATA", card: url, into: root,
                                                             helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner()))
            XCTAssertThrowsError(try MemoryCardSaves.export(save: "NOPE", card: url, into: root,
                                                             helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner()))
            let cancelled = ConversionRunner(); cancelled.cancel()
            XCTAssertThrowsError(try MemoryCardSaves.export(save: "BESLES-54321EMPTY", card: url, into: root,
                                                             helper: URL(fileURLWithPath: "/nonexistent"), runner: cancelled))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BESLES-54321EMPTY.ps2save").path))
        }
        XCTAssertEqual(try FileDigest.sha256(url), before)
    }

    func testDeletedEntriesAreOmittedByDesign() throws {
        var built = build(saves: standardSaves())
        // Clear EXISTS on the second save (root entry 4 at page 23): it is
        // deleted, not a save.
        var raw = built.data
        raw[23 * 528] = 0x04; raw[23 * 528 + 1] = 0x27
        built = Built(data: raw, clusters: built.clusters, alloc: built.alloc)
        let url = try cardURL(built.data)
        defer { try? FileManager.default.removeItem(at: url) }
        let saves = try MemoryCardSaves.inventory(card: url, helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner())
        XCTAssertEqual(saves.map(\.name), ["BASLUS-12345GAMEDATA"])
    }

    func testDamagedCardsFailPrecisely() throws {
        func mutate(_ base: Data, _ change: (inout Data) -> Void, contains message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            var raw = base
            change(&raw)
            let url = try cardURL(raw)
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                _ = try MemoryCardSaves.inventory(card: url, helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner())
                XCTFail("expected failure containing \(message)", file: file, line: line)
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(message), "got: \(error.localizedDescription); lacks: \(message)", file: file, line: line)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".ps2save"))
        }
        let good = build(saves: standardSaves()).data
        // A card without the formatted-card magic is routed to the encrypted
        // path first (it might be a VME), so it fails there — never listed.
        do {
            var raw = good; raw[0] = 0x58
            let url = try cardURL(raw)
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try MemoryCardSaves.inventory(card: url, helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner())
            XCTFail("unformatted card must not list")
        } catch { XCTAssertTrue(!error.localizedDescription.isEmpty) }
        try mutate(good, { $0[0x28] = 0; $0[0x29] = 0 }, contains: "geometry")
        try mutate(good, { $0[0x150] = 1 }, contains: "type 2")
        try mutate(good, {
            $0.replaceSubrange(0x50..<0x54, with: Data([0x78, 0x56, 0x34, 0x12]))
        }, contains: "FAT index")
        try mutate(good, {
            // FAT entry rel 2 (icon.sys chain) -> self loop. FAT abs 9 = pages 18,19.
            $0.replaceSubrange(18 * 528 + 8..<18 * 528 + 12, with: Data([0x02, 0, 0, 0x80]))
        }, contains: "cyclic")
        try mutate(good, {
            $0.replaceSubrange(18 * 528 + 8..<18 * 528 + 12, with: Data([0, 0, 0, 0]))
        }, contains: "free cluster")
        try mutate(good, {
            // Cut data.bin (2500 bytes, rel 3,4,5) after two clusters.
            $0.replaceSubrange(18 * 528 + 16..<18 * 528 + 20, with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        }, contains: "ends before")
        try mutate(good, {
            // data.bin dirent is the 4th save entry at page 35: wild length.
            $0.replaceSubrange(35 * 528 + 4..<35 * 528 + 8, with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        }, contains: "more bytes than the card can hold")
        try mutate(good, {
            // empty.txt (5th save entry at page 36): give it a cluster.
            $0.replaceSubrange(36 * 528 + 0x10..<36 * 528 + 0x14, with: Data([0x02, 0, 0, 0]))
        }, contains: "stray cluster")
        try mutate(good, {
            // icon.sys name (third save entry at page 34): drop the NUL terminator.
            for i in 0..<32 { $0[34 * 528 + 0x40 + i] = 0x41 }
        }, contains: "no terminated name")
        try mutate(good, {
            // Root "." renamed.
            $0[20 * 528 + 0x40] = 0x58
        }, contains: "link entries")
        try mutate(good, {
            // data.bin flagged as a directory.
            $0[35 * 528] = 0x27; $0[35 * 528 + 1] = 0x84
        }, contains: "nested folder")
        try mutate(good, {
            // Second save (root entry 4 at page 23) renamed onto the first.
            let name = Data("BASLUS-12345GAMEDATA".utf8)
            $0.replaceSubrange(23 * 528 + 0x40..<23 * 528 + 0x40 + name.count, with: name)
        }, contains: "twice")
        try mutate(good, {
            // Second save flagged as a file.
            $0[23 * 528] = 0x17; $0[23 * 528 + 1] = 0x84
        }, contains: "not a save folder")
        // Extended and truncated forms.
        var extended = good; extended.append(Data(count: 16384))
        try mutate(extended, { _ in }, contains: "extended 16 KiB")
        try mutate(good.dropLast(528), { _ in }, contains: "declared geometry")
        // Symlinked cards are never followed.
        try temporary { root in
            let real = root.appendingPathComponent("real.VMC"); try good.write(to: real)
            let link = root.appendingPathComponent("link.VMC")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            do {
                _ = try MemoryCardSaves.inventory(card: link, helper: URL(fileURLWithPath: "/nonexistent"), runner: ConversionRunner())
                XCTFail("symlinked card must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("symbolic link"), error.localizedDescription)
            }
        }
    }

    func testTruncationAtAnyOffsetFailsClosedNeverTraps() throws {
        // Every truncation must throw a ConversionFailure (never trap), and
        // every extension must fail the size check. Sizes step across page,
        // spare, FAT, directory and payload boundaries of the small fixture.
        let good = build(saves: standardSaves()).data
        var sizes = [0, 1, 100, 511, 512, 527, 528, 529, 1056, 2048, 10000, 30000]
        sizes += [good.count - 529, good.count - 528, good.count - 1]
        sizes += [good.count + 1, good.count + 16383, good.count + 16385]
        try temporary { root in
            for size in sizes {
                let url = root.appendingPathComponent("t-\(size).VMC")
                var bytes = Data(good.prefix(min(size, good.count)))
                if size > good.count { bytes.append(Data(count: size - good.count)) }
                try bytes.write(to: url)
                do {
                    _ = try MemoryCardSaves.inventory(card: url, helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
                    XCTFail("truncated/extended size \(size) must fail")
                } catch {
                    XCTAssertFalse(error.localizedDescription.isEmpty, "size \(size)")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".ps2save"))
            }
        }
    }
}
