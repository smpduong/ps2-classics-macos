// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

/// Save import into new card copies. Fixture cards are built in-test (small
/// 64-cluster geometry for speed, plus one full 8 MiB geometry); the source
/// card is never modified and every refusal publishes nothing.
final class MemoryCardImportTests: XCTestCase {
    static let icon = Data(0..<100)
    static let payload = Data((0..<2500).map { UInt8(($0 * 37) % 256) })
    static let last: UInt32 = 0xFFFFFFFF
    static let used: UInt32 = 0x80000000

    /// Minimal standard-layout card. `extra` adds files to the first save
    /// (e.g. filler for the no-space case).
    static func build(saves: [(String, [(String, Data)])], extra: [(String, Data)] = [],
                      clusters: Int = 64, alloc: Int = 10, ppc: Int = 2) -> Data {
        let pages = clusters * ppc
        let cbytes = ppc * 512
        var raw = Data(count: pages * 528)
        func write(_ bytes: Data, at offset: Int) { raw.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        func page(_ p: Int, _ data: Data) { write(data, at: p * 528) }
        func cluster(_ c: Int, _ data: Data) {
            var padded = Data(Data(data).prefix(cbytes))
            padded.append(contentsOf: repeatElement(0, count: cbytes - padded.count))
            for j in 0..<ppc { page(c * ppc + j, Data(padded[j * 512..<(j + 1) * 512])) }
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
        let per = cbytes / 512
        let rootChain = take((2 + saves.count + per - 1) / per)
        var rootEntries = [dirent(mode: 0x8427, length: 0, cluster: 0, name: "."),
                           dirent(mode: 0x8427, length: 0, cluster: 0, name: "..")]
        var dirBlobs = [(chain: [Int], entries: [Data])]()
        for (index, (saveName, files)) in saves.enumerated() {
            var entries = [dirent(mode: 0x8427, length: 0, cluster: 0, name: ".", dirEntry: UInt32(rootEntries.count)),
                           dirent(mode: 0x8427, length: 0, cluster: 0, name: "..")]
            let allFiles = files + (index == 0 ? extra : [])
            for (fname, fdata) in allFiles {
                if fdata.isEmpty {
                    entries.append(dirent(mode: 0x8417, length: 0, cluster: Self.last, name: fname))
                } else {
                    let need = (fdata.count + cbytes - 1) / cbytes
                    let chain = take(need)
                    var blob = fdata; blob.append(contentsOf: repeatElement(0, count: need * cbytes - fdata.count))
                    for (rel, i) in zip(chain, 0..<need) { cluster(alloc + rel, Data(blob[i * cbytes..<(i + 1) * cbytes])) }
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
        let perFat = cbytes / 4
        let fatClusters = (fatCount + perFat - 1) / perFat
        var indirect = [UInt32](repeating: Self.last, count: perFat)
        for i in 0..<fatClusters { indirect[i] = UInt32(9 + i) }
        var indirectData = Data(); for w in indirect { indirectData.append(u32(w)) }
        cluster(8, indirectData)
        var flat = fat; flat.append(contentsOf: repeatElement(0, count: fatClusters * perFat - fat.count))
        for i in 0..<fatClusters {
            var blob = Data(); for w in flat[i * perFat..<(i + 1) * perFat] { blob.append(u32(w)) }
            cluster(9 + i, blob)
        }
        var sb = Data(count: 512)
        sb.replaceSubrange(0..<28, with: Data("Sony PS2 Memory Card Format ".utf8))
        sb.replaceSubrange(0x1C..<0x1C + 12, with: Data([0x31, 0x2E, 0x32, 0x2E, 0x30, 0x2E, 0x30, 0, 0, 0, 0, 0]))
        func u16(_ v: Int, at offset: Int) { sb[offset] = UInt8(v & 255); sb[offset + 1] = UInt8(v >> 8) }
        func w32(_ v: Int, at offset: Int) { let d = u32(UInt32(v)); sb.replaceSubrange(offset..<offset + 4, with: d) }
        u16(512, at: 0x28); u16(ppc, at: 0x2A); u16(16, at: 0x2C); u16(0xFF00, at: 0x2E)
        w32(clusters, at: 0x30); w32(alloc, at: 0x34); w32(8135, at: 0x38); w32(0, at: 0x3C)
        w32(1023, at: 0x40); w32(1022, at: 0x44)
        var ifc = Data(); ifc.append(u32(8)); for _ in 1..<32 { ifc.append(u32(Self.last)) }
        sb.replaceSubrange(0x50..<0x50 + 128, with: ifc)
        var bad = Data(); for _ in 0..<32 { bad.append(u32(Self.last)) }
        sb.replaceSubrange(0xD0..<0xD0 + 128, with: bad)
        sb[0x150] = 2; sb[0x151] = 0x52
        page(0, sb)
        return raw
    }

    func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func write(_ data: Data, name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    func helper() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PS2_TEST_HELPER"] else { throw XCTSkip("Set PS2_TEST_HELPER") }
        return URL(fileURLWithPath: path)
    }

    /// Exports GAMEDATA from card A, returning the .ps2save folder.
    func exportGameData(from card: URL, in root: URL) throws -> URL {
        let saves = try MemoryCardSaves.inventory(card: card, helper: URL(fileURLWithPath: "/nonexistent"),
                                                  runner: ConversionRunner())
        XCTAssertEqual(saves.map(\.name), ["BASLUS-12345GAMEDATA", "BESLES-54321EMPTY"])
        return try MemoryCardSaves.export(save: "BASLUS-12345GAMEDATA", card: card, into: root,
                                          helper: URL(fileURLWithPath: "/nonexistent"),
                                          runner: ConversionRunner())
    }

    func testRoundTripExportImportPreservesEverything() throws {
        let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA",
                                        [("icon.sys", Self.icon), ("data.bin", Self.payload), ("empty.txt", Data())]),
                                       ("BESLES-54321EMPTY", [])])
        let cardB = Self.build(saves: [("BESLES-99999OTHER", [("note.dat", Data("hello".utf8))])])
        try temporary { root in
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let urlB = try write(cardB, name: "b.VMC", in: root)
            let beforeA = try FileDigest.sha256(urlA), beforeB = try FileDigest.sha256(urlB)
            let exported = try exportGameData(from: urlA, in: root)
            let destination = root.appendingPathComponent("b-with-save.VMC")
            let result = try MemoryCardImport.importSave(exported, card: urlB, destination: destination,
                                                         helper: URL(fileURLWithPath: "/nonexistent"),
                                                         runner: ConversionRunner())
            XCTAssertEqual(result.save, "BASLUS-12345GAMEDATA")
            XCTAssertEqual(result.files.map(\.name).sorted(), ["data.bin", "empty.txt", "icon.sys"])
            XCTAssertEqual(result.totalBytes, 2600)
            // Sources untouched; the result parses with exact bytes.
            XCTAssertEqual(try FileDigest.sha256(urlA), beforeA)
            XCTAssertEqual(try FileDigest.sha256(urlB), beforeB)
            let saves = try MemoryCardSaves.inventory(card: destination,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            XCTAssertEqual(saves.map(\.name).sorted(), ["BASLUS-12345GAMEDATA", "BESLES-99999OTHER"])
            let imported = saves.first(where: { $0.name == "BASLUS-12345GAMEDATA" })!
            XCTAssertEqual(imported.files.first(where: { $0.name == "icon.sys" })?.sha256,
                           FileDigest.sha256(data: Self.icon))
            XCTAssertEqual(imported.files.first(where: { $0.name == "data.bin" })?.sha256,
                           FileDigest.sha256(data: Self.payload))
            XCTAssertEqual(result.cardSHA256, try FileDigest.sha256(destination))
        }
    }

    func testCollisionNoSpaceForeignAndExclusiveRefusals() throws {
        let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA", [("icon.sys", Self.icon)]),
                                       ("BESLES-54321EMPTY", [])])
        // 54 clusters; occupied: root 2 + dir 2 + icon 1 = 5, free 49.
        // Import needs icon 1 + dir 2 = 3; filler leaves too few.
        let filler = Data(count: 48 * 1024)
        let full = Self.build(saves: [("BESLES-54321EMPTY", [])], extra: [("filler.bin", filler)])
        try temporary { root in
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let urlFull = try write(full, name: "full.VMC", in: root)
            let exported = try exportGameData(from: urlA, in: root)
            // Collision: the save already lives on the target.
            do {
                _ = try MemoryCardImport.importSave(exported, card: urlA,
                                                    destination: root.appendingPathComponent("collision.VMC"),
                                                    helper: URL(fileURLWithPath: "/nonexistent"),
                                                    runner: ConversionRunner())
                XCTFail("collision must refuse")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("already exists"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("collision.VMC").path))
            // No space on the nearly full card.
            do {
                _ = try MemoryCardImport.importSave(exported, card: urlFull,
                                                    destination: root.appendingPathComponent("nospace.VMC"),
                                                    helper: URL(fileURLWithPath: "/nonexistent"),
                                                    runner: ConversionRunner())
                XCTFail("full card must refuse")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("free clusters"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("nospace.VMC").path))
            // Existing destination is never replaced.
            let taken = root.appendingPathComponent("taken.VMC")
            try Data("preserve".utf8).write(to: taken)
            let cardB = Self.build(saves: [("BESLES-99999OTHER", [])])
            let urlB = try write(cardB, name: "b.VMC", in: root)
            let beforeB = try FileDigest.sha256(urlB)
            XCTAssertThrowsError(try MemoryCardImport.importSave(exported, card: urlB, destination: taken,
                                                                 helper: URL(fileURLWithPath: "/nonexistent"),
                                                                 runner: ConversionRunner()))
            XCTAssertEqual(try String(contentsOf: taken), "preserve")
            // Foreign folders and tampered payloads are refused up front.
            let foreign = root.appendingPathComponent("foreign.ps2save")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
            try Data("nope".utf8).write(to: foreign.appendingPathComponent("manifest.json"))
            XCTAssertThrowsError(try MemoryCardImport.importSave(foreign, card: urlB,
                                                                 destination: root.appendingPathComponent("foreign.VMC"),
                                                                 helper: URL(fileURLWithPath: "/nonexistent"),
                                                                 runner: ConversionRunner()))
            let notSave = root.appendingPathComponent("plain")
            try FileManager.default.createDirectory(at: notSave, withIntermediateDirectories: false)
            XCTAssertThrowsError(try MemoryCardImport.importSave(notSave, card: urlB,
                                                                 destination: root.appendingPathComponent("plain.VMC"),
                                                                 helper: URL(fileURLWithPath: "/nonexistent"),
                                                                 runner: ConversionRunner()))
            let tamperedDir = root.appendingPathComponent("tampered.ps2save")
            try FileManager.default.copyItem(at: exported, to: tamperedDir)
            // Same-size corruption exercises the checksum path, not the size path.
            try Data(repeating: 9, count: Self.icon.count).write(to: tamperedDir.appendingPathComponent("icon.sys"))
            do {
                _ = try MemoryCardImport.importSave(tamperedDir, card: urlB,
                                                    destination: root.appendingPathComponent("tampered.VMC"),
                                                    helper: URL(fileURLWithPath: "/nonexistent"),
                                                    runner: ConversionRunner())
                XCTFail("tampered export must refuse")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
            }
            // Mismatched destination type is refused without helper use.
            XCTAssertThrowsError(try MemoryCardImport.importSave(exported, card: urlB,
                                                                 destination: root.appendingPathComponent("type.VME"),
                                                                 helper: URL(fileURLWithPath: "/nonexistent"),
                                                                 runner: ConversionRunner()))
            // Cancellation publishes nothing.
            let cancelled = ConversionRunner(); cancelled.cancel()
            XCTAssertThrowsError(try MemoryCardImport.importSave(exported, card: urlB,
                                                                 destination: root.appendingPathComponent("cancelled.VMC"),
                                                                 helper: URL(fileURLWithPath: "/nonexistent"),
                                                                 runner: cancelled))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.VMC").path))
            XCTAssertEqual(try FileDigest.sha256(urlB), beforeB)
        }
    }

    func testEncryptedImportRoundTrip() throws {
        let helper = try helper()
        let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA", [("icon.sys", Self.icon), ("data.bin", Self.payload)]),
                                       ("BESLES-54321EMPTY", [])],
                               clusters: 8192, alloc: 41)
        let cardB = Self.build(saves: [("BESLES-99999OTHER", [("note.dat", Data("hi".utf8))])],
                               clusters: 8192, alloc: 41)
        try temporary { root in
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let rawB = try write(cardB, name: "b.VMC", in: root)
            let encB = root.appendingPathComponent("b.VME")
            try ConversionRunner().run(arguments: ["vmc-encrypt", rawB.path, encB.path],
                                       helper: helper, progress: { _ in })
            let before = try FileDigest.sha256(encB)
            let exported = try exportGameData(from: urlA, in: root)
            let destination = root.appendingPathComponent("b-with-save.VME")
            let result = try MemoryCardImport.importSave(exported, card: encB, destination: destination,
                                                         helper: helper, runner: ConversionRunner())
            XCTAssertEqual(result.save, "BASLUS-12345GAMEDATA")
            XCTAssertEqual(try FileDigest.sha256(encB), before)
            // The published encrypted file decrypts to a card with the save.
            let check = root.appendingPathComponent("check.VMC")
            try ConversionRunner().run(arguments: ["vmc-decrypt", destination.path, check.path],
                                       helper: helper, progress: { _ in })
            let saves = try MemoryCardSaves.inventory(card: check,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            let imported = try XCTUnwrap(saves.first(where: { $0.name == "BASLUS-12345GAMEDATA" }))
            XCTAssertEqual(imported.files.first(where: { $0.name == "data.bin" })?.sha256,
                           FileDigest.sha256(data: Self.payload))
            XCTAssertNotNil(saves.first(where: { $0.name == "BESLES-99999OTHER" }))
        }
    }

    func testFullSizeGeometryRoundTrip() throws {
        let helper = try helper()
        let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA", [("icon.sys", Self.icon), ("data.bin", Self.payload)]),
                                       ("BESLES-54321EMPTY", [])],
                               clusters: 8192, alloc: 41)
        let cardB = Self.build(saves: [("BESLES-99999OTHER", [])], clusters: 8192, alloc: 41)
        XCTAssertEqual(cardA.count, 8650752)
        try temporary { root in
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let urlB = try write(cardB, name: "b.VMC", in: root)
            let exported = try exportGameData(from: urlA, in: root)
            let destination = root.appendingPathComponent("b-with-save.VMC")
            _ = try MemoryCardImport.importSave(exported, card: urlB, destination: destination,
                                                helper: helper,
                                                runner: ConversionRunner())
            let saves = try MemoryCardSaves.inventory(card: destination, helper: helper,
                                                      runner: ConversionRunner())
            XCTAssertEqual(saves.map(\.name).sorted(), ["BASLUS-12345GAMEDATA", "BESLES-99999OTHER"])
        }
    }

    func testSinglePageClusterGeometryRoundTrip() throws {
        // One page per cluster exercises every geometry-driven path with
        // different FAT packing and directory density.
        let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA", [("icon.sys", Self.icon), ("data.bin", Self.payload)])],
                               clusters: 64, alloc: 10, ppc: 1)
        let cardB = Self.build(saves: [("BESLES-99999OTHER", [("note.dat", Data("hi".utf8))])],
                               clusters: 64, alloc: 10, ppc: 1)
        try temporary { root in
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let urlB = try write(cardB, name: "b.VMC", in: root)
            let beforeB = try FileDigest.sha256(urlB)
            let exported = try MemoryCardSaves.export(save: "BASLUS-12345GAMEDATA", card: urlA, into: root,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            let destination = root.appendingPathComponent("b-with-save.VMC")
            let result = try MemoryCardImport.importSave(exported, card: urlB, destination: destination,
                                                         helper: URL(fileURLWithPath: "/nonexistent"),
                                                         runner: ConversionRunner())
            XCTAssertEqual(result.save, "BASLUS-12345GAMEDATA")
            XCTAssertEqual(try FileDigest.sha256(urlB), beforeB)
            let saves = try MemoryCardSaves.inventory(card: destination,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            XCTAssertEqual(saves.map(\.name).sorted(), ["BASLUS-12345GAMEDATA", "BESLES-99999OTHER"])
            XCTAssertEqual(saves.first(where: { $0.name == "BASLUS-12345GAMEDATA" })?
                .files.first(where: { $0.name == "data.bin" })?.sha256,
                FileDigest.sha256(data: Self.payload))
        }
    }

    func testWidePageGeometryRefusesImportPrecisely() throws {
        // 1024-byte pages parse for browsing, but import (ECC is defined per
        // 512-byte page) refuses with a precise reason. Built by hand: a
        // valid 16-cluster geometry with 1040-byte stride throughout.
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
        var raw = Data(count: 16 * 1040)
        func page(_ p: Int, _ data: Data) {
            raw.replaceSubrange(p * 1040..<p * 1040 + data.count, with: data)
        }
        var sb = Data(count: 1024)
        sb.replaceSubrange(0..<28, with: Data("Sony PS2 Memory Card Format ".utf8))
        func u16(_ v: Int, at offset: Int) { sb[offset] = UInt8(v & 255); sb[offset + 1] = UInt8(v >> 8) }
        func w32(_ v: Int, at offset: Int) { let d = u32(UInt32(v)); sb.replaceSubrange(offset..<offset + 4, with: d) }
        u16(1024, at: 0x28); u16(1, at: 0x2A); u16(16, at: 0x2C); u16(0xFF00, at: 0x2E)
        w32(16, at: 0x30); w32(10, at: 0x34); w32(8135, at: 0x38); w32(0, at: 0x3C)
        w32(1023, at: 0x40); w32(1022, at: 0x44)
        var ifc = Data(); ifc.append(u32(8)); for _ in 1..<32 { ifc.append(u32(Self.last)) }
        sb.replaceSubrange(0x50..<0x50 + 128, with: ifc)
        var bad = Data(); for _ in 0..<32 { bad.append(u32(Self.last)) }
        sb.replaceSubrange(0xD0..<0xD0 + 128, with: bad)
        sb[0x150] = 2; sb[0x151] = 0x52
        page(0, sb)
        var indirect = Data(); indirect.append(u32(9)); for _ in 1..<256 { indirect.append(u32(Self.last)) }
        page(8, indirect)
        var fat = Data()
        for w: UInt32 in [0x80000001, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0] { fat.append(u32(w)) }
        fat.append(Data(count: 1024 - fat.count))
        page(9, fat)
        var root = dirent(mode: 0x8427, length: 3, cluster: 0, name: ".")
        root.append(dirent(mode: 0x8427, length: 0, cluster: 0, name: ".."))
        page(10, root)
        var rootB = dirent(mode: 0x8427, length: 2, cluster: 2, name: "BESLES-99999OTHER")
        rootB.append(Data(count: 512))
        page(11, rootB)
        var savedir = dirent(mode: 0x8427, length: 0, cluster: 0, name: ".", dirEntry: 2)
        savedir.append(dirent(mode: 0x8427, length: 0, cluster: 0, name: ".."))
        page(12, savedir)
        try temporary { root in
            let urlB = try write(raw, name: "b.VMC", in: root)
            let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA", [("icon.sys", Self.icon)]),
                                           ("BESLES-54321EMPTY", [])])
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let exported = try exportGameData(from: urlA, in: root)
            XCTAssertEqual(try MemoryCardSaves.inventory(card: urlB,
                                                          helper: URL(fileURLWithPath: "/nonexistent"),
                                                          runner: ConversionRunner()).map(\.name),
                           ["BESLES-99999OTHER"])
            do {
                _ = try MemoryCardImport.importSave(exported, card: urlB,
                                                    destination: root.appendingPathComponent("wide.VMC"),
                                                    helper: URL(fileURLWithPath: "/nonexistent"),
                                                    runner: ConversionRunner())
                XCTFail("wide pages must refuse import")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("1024-byte pages"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("wide.VMC").path))
        }
    }

    func testRootExtensionImport() throws {
        // A root directory filled to capacity forces the single-cluster root
        // growth path: relink, zero-filled extension, slot math, count update.
        let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA", [("icon.sys", Self.icon)]),
                                       ("BESLES-54321EMPTY", [])])
        // Small card root holds 4 entries per 2 clusters; two saves fill it.
        let cardB = Self.build(saves: [("BESLES-00001ONE", [("a.dat", Data("one".utf8))]),
                                       ("BESLES-00002TWO", [("b.dat", Data("two".utf8))])])
        try temporary { root in
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let urlB = try write(cardB, name: "b.VMC", in: root)
            let beforeB = try FileDigest.sha256(urlB)
            XCTAssertEqual(try MemoryCardSaves.inventory(card: urlB,
                                                          helper: URL(fileURLWithPath: "/nonexistent"),
                                                          runner: ConversionRunner()).map(\.name),
                           ["BESLES-00001ONE", "BESLES-00002TWO"])
            let exported = try MemoryCardSaves.export(save: "BASLUS-12345GAMEDATA", card: urlA, into: root,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            let destination = root.appendingPathComponent("b-grown.VMC")
            let result = try MemoryCardImport.importSave(exported, card: urlB, destination: destination,
                                                         helper: URL(fileURLWithPath: "/nonexistent"),
                                                         runner: ConversionRunner())
            XCTAssertEqual(result.save, "BASLUS-12345GAMEDATA")
            XCTAssertEqual(try FileDigest.sha256(urlB), beforeB)
            let saves = try MemoryCardSaves.inventory(card: destination,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            XCTAssertEqual(saves.map(\.name).sorted(),
                           ["BASLUS-12345GAMEDATA", "BESLES-00001ONE", "BESLES-00002TWO"])
            XCTAssertEqual(saves.first(where: { $0.name == "BESLES-00002TWO" })?
                .files.first(where: { $0.name == "b.dat" })?.sha256,
                FileDigest.sha256(data: Data("two".utf8)))
        }
    }

    func testDeletedSlotReuseImport() throws {
        // A deleted root entry is reused in place: the root length does not
        // grow and the other save is untouched.
        var cardB = Self.build(saves: [("BESLES-99999OTHER", [("note.dat", Data("hi".utf8))]),
                                       ("BESLES-00000DEAD", [("old.dat", Data("old".utf8))])])
        // Clear EXISTS on the second save's root record (root cluster 0 is
        // absolute cluster 10, pages 20-21; fourth entry at page 23).
        cardB[23 * 528] = 0x04; cardB[23 * 528 + 1] = 0x27
        let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA", [("icon.sys", Self.icon)]),
                                       ("BESLES-54321EMPTY", [])])
        try temporary { root in
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let urlB = try write(cardB, name: "b.VMC", in: root)
            let exported = try MemoryCardSaves.export(save: "BASLUS-12345GAMEDATA", card: urlA, into: root,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            let destination = root.appendingPathComponent("b-reused.VMC")
            _ = try MemoryCardImport.importSave(exported, card: urlB, destination: destination,
                                                helper: URL(fileURLWithPath: "/nonexistent"),
                                                runner: ConversionRunner())
            let saves = try MemoryCardSaves.inventory(card: destination,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            XCTAssertEqual(saves.map(\.name).sorted(), ["BASLUS-12345GAMEDATA", "BESLES-99999OTHER"])
            // The clusters of the deleted save are still marked used, so the
            // importer must not have reallocated them: the new save's files
            // hash exactly.
            XCTAssertEqual(saves.first(where: { $0.name == "BASLUS-12345GAMEDATA" })?
                .files.first(where: { $0.name == "icon.sys" })?.sha256,
                FileDigest.sha256(data: Self.icon))
        }
    }

    func testLargeFileSpanningFATClusters() throws {
        // A 300 KiB file spans two FAT clusters, exercising multi-cluster
        // FAT reads, writes and chain validation (full-size geometry, so the
        // helper round trip runs too).
        let helper = try helper()
        let big = Data((0..<300 * 1024).map { UInt8(($0 * 31 + 7) % 256) })
        let cardA = Self.build(saves: [("BASLUS-12345GAMEDATA", [("big.bin", big)]),
                                       ("BESLES-54321EMPTY", [])],
                               clusters: 8192, alloc: 41)
        let cardB = Self.build(saves: [("BESLES-99999OTHER", [])], clusters: 8192, alloc: 41)
        try temporary { root in
            let urlA = try write(cardA, name: "a.VMC", in: root)
            let urlB = try write(cardB, name: "b.VMC", in: root)
            let exported = try MemoryCardSaves.export(save: "BASLUS-12345GAMEDATA", card: urlA, into: root,
                                                      helper: helper,
                                                      runner: ConversionRunner())
            let destination = root.appendingPathComponent("b-big.VMC")
            let result = try MemoryCardImport.importSave(exported, card: urlB, destination: destination,
                                                         helper: helper,
                                                         runner: ConversionRunner())
            XCTAssertEqual(result.totalBytes, big.count)
            let saves = try MemoryCardSaves.inventory(card: destination,
                                                      helper: URL(fileURLWithPath: "/nonexistent"),
                                                      runner: ConversionRunner())
            XCTAssertEqual(saves.first(where: { $0.name == "BASLUS-12345GAMEDATA" })?
                .files.first(where: { $0.name == "big.bin" })?.sha256,
                FileDigest.sha256(data: big))
        }
    }
}
