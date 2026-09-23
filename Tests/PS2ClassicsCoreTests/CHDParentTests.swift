// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CryptoKit
@testable import PS2ClassicsCore

/// Parent-dependent CHD support. Fixtures are built in-test (minimal v5
/// uncompressed DVD images, no binaries in Git); the helper checks run
/// against PS2_TEST_HELPER like the other helper-gated suites.
final class CHDParentTests: XCTestCase {
    static let hunk = 16384

    /// Tiny ISO9660 image with a SYSTEM.CNF boot ID, padded to whole hunks.
    static func logical() -> Data {
        var data = Data(repeating: 0, count: 24 * 2048)
        let p = 16 * 2048
        data[p] = 1; data.replaceSubrange(p + 1..<p + 6, with: Data("CD001".utf8)); data[p + 6] = 1
        data[p + 80] = 24; data[p + 87] = 24; data[p + 129] = 8; data[p + 130] = 8
        data[p + 156] = 34; data[p + 158] = 20; data[p + 166] = 8; data[p + 167] = 8
        let cnf = Data("BOOT2 = cdrom0:\\SLUS_123.45;1\r\n".utf8)
        let r = 20 * 2048, name = Data("SYSTEM.CNF;1".utf8)
        data[r] = 46; data[r + 2] = 21; data[r + 10] = UInt8(cnf.count); data[r + 32] = UInt8(name.count)
        data.replaceSubrange(r + 33..<r + 33 + name.count, with: name)
        data.replaceSubrange(21 * 2048..<21 * 2048 + cnf.count, with: cnf)
        while data.count % hunk != 0 { data.append(0) }
        return data
    }

    /// Minimal valid v5 uncompressed DVD CHD. Returns the stated combined
    /// header SHA-1 (bytes 84..<104) for child binding.
    @discardableResult
    static func writeParent(_ url: URL, logical: Data) throws -> Data {
        precondition(logical.count > 0 && logical.count % hunk == 0)
        let hunks = logical.count / hunk
        let dataStart = ((124 + hunks * 4 + hunk - 1) / hunk) * hunk
        let metaOffset = dataStart + logical.count
        func be32(_ v: Int) -> Data {
            Data([UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)])
        }
        func be64(_ v: Int) -> Data {
            be32(v >> 32) + be32(v & 0xFFFFFFFF)
        }
        let rawSHA1 = Data(Insecure.SHA1.hash(data: logical))
        let combined = Data(Insecure.SHA1.hash(data: rawSHA1))
        var header = Data("MComprHD".utf8) + be32(124) + be32(5) + be32(0) + be32(0) + be32(0) + be32(0)
        header += be64(logical.count) + be64(124) + be64(metaOffset) + be32(hunk) + be32(2048)
        header += rawSHA1 + combined + Data(count: 20)
        var out = header
        for i in 0..<hunks { out += be32((dataStart + i * hunk) / hunk) }
        out += Data(count: dataStart - out.count)
        out += logical
        out += Data("DVD ".utf8) + be32(0) + be64(0)
        try out.write(to: url, options: .withoutOverwriting)
        return combined
    }

    static func writeChild(_ url: URL, parent: URL, parentsha1: Data) throws {
        var raw = try Data(contentsOf: parent)
        raw.replaceSubrange(104..<124, with: parentsha1)
        try raw.write(to: url, options: .withoutOverwriting)
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

    func pair(in root: URL) throws -> (parent: URL, child: URL, logical: Data, combined: Data) {
        let logical = Self.logical()
        let parent = root.appendingPathComponent("parent.chd")
        let combined = try Self.writeParent(parent, logical: logical)
        let child = root.appendingPathComponent("child.chd")
        try Self.writeChild(child, parent: parent, parentsha1: combined)
        return (parent, child, logical, combined)
    }

    func testParentPairExpandsByteExact() throws {
        let helper = try helper()
        try temporary { root in
            let (parent, child, logical, _) = try pair(in: root)
            let probe = try CHDImporter.inspect(child, parent: parent, helper: helper, runner: ConversionRunner())
            XCTAssertTrue(probe.isSupported)
            XCTAssertEqual(probe.expandedByteCount, UInt64(logical.count))
            XCTAssertEqual(probe.gameID, "SLUS12345")
            let runner = ConversionRunner()
            let expanded = root.appendingPathComponent("expanded.image")
            try runner.run(arguments: ["extract-chd", child.path, expanded.path, parent.path],
                           helper: helper, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: expanded), logical)
        }
    }

    func testInspectWithoutParentDeclaresRequirement() throws {
        let helper = try helper()
        try temporary { root in
            let (_, child, _, combined) = try pair(in: root)
            let probe = try CHDImporter.inspect(child, helper: helper, runner: ConversionRunner())
            XCTAssertFalse(probe.isSupported)
            XCTAssertTrue(probe.requiresParent)
            XCTAssertEqual(probe.parentSHA1, combined.map { String(format: "%02x", $0) }.joined())
            XCTAssertNil(probe.expandedByteCount)
        }
    }

    func testExtractWithoutParentFailsPrecisely() throws {
        let helper = try helper()
        try temporary { root in
            let (_, child, _, _) = try pair(in: root)
            let target = root.appendingPathComponent("nope.image")
            do {
                try ConversionRunner().run(arguments: ["extract-chd", child.path, target.path],
                                           helper: helper, progress: { _ in })
                XCTFail("parentless extraction must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Parent-dependent"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testWrongParentFailsIdentity() throws {
        let helper = try helper()
        try temporary { root in
            let (_, child, _, _) = try pair(in: root)
            var other = Self.logical(); other[100] ^= 1
            let stranger = root.appendingPathComponent("stranger.chd")
            _ = try Self.writeParent(stranger, logical: other)
            do {
                _ = try CHDImporter.inspect(child, parent: stranger, helper: helper, runner: ConversionRunner())
                XCTFail("wrong parent must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("identity mismatch"), error.localizedDescription)
            }
        }
    }

    func testSelfParentAndNestingAndUnneededAreRejected() throws {
        let helper = try helper()
        try temporary { root in
            let (parent, child, _, combined) = try pair(in: root)
            XCTAssertThrowsError(try CHDImporter.inspect(child, parent: child, helper: helper, runner: ConversionRunner()))
            do {
                _ = try CHDImporter.inspect(child, parent: child, helper: helper, runner: ConversionRunner())
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("same file"), error.localizedDescription)
            }
            // Grandchild declares the (parent-dependent) child as its parent.
            let grandchild = root.appendingPathComponent("grandchild.chd")
            try Self.writeChild(grandchild, parent: child,
                                parentsha1: Data(try Data(contentsOf: child)[84..<104]))
            do {
                _ = try CHDImporter.inspect(grandchild, parent: child, helper: helper, runner: ConversionRunner())
                XCTFail("nested parents must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("single-level"), error.localizedDescription)
            }
            // A standalone image with a parent selection is a user error.
            do {
                _ = try CHDImporter.inspect(parent, parent: child, helper: helper, runner: ConversionRunner())
                XCTFail("unneeded parent must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("declares no parent"), error.localizedDescription)
            }
            _ = combined
        }
    }

    func testVersionAndFormatRejectionsArePrecise() throws {
        let helper = try helper()
        try temporary { root in
            var v4 = try Data(contentsOf: pair(in: root).parent)
            v4[12] = 0; v4[13] = 0; v4[14] = 0; v4[15] = 4
            let v4URL = root.appendingPathComponent("v4.chd"); try v4.write(to: v4URL)
            do {
                _ = try CHDImporter.inspect(v4URL, helper: helper, runner: ConversionRunner())
                XCTFail("version 4 must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("version 4"), error.localizedDescription)
            }
            let garbage = root.appendingPathComponent("garbage.chd")
            try Data(count: 256).write(to: garbage)
            do {
                _ = try CHDImporter.inspect(garbage, helper: helper, runner: ConversionRunner())
                XCTFail("non-CHD must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Not a CHD image"), error.localizedDescription)
            }
        }
    }

    func testNeedsParentLogic() {
        var disc = GameDisc(source: URL(fileURLWithPath: "/x/child.chd"), gameID: "")
        XCTAssertFalse(disc.needsParent)
        disc.chdParentSHA1 = String(repeating: "a", count: 40)
        XCTAssertTrue(disc.needsParent)
        disc.chdParent = URL(fileURLWithPath: "/x/parent.chd")
        XCTAssertFalse(disc.needsParent)
        var iso = GameDisc(source: URL(fileURLWithPath: "/x/game.iso"), gameID: "SLUS12345")
        iso.chdParentSHA1 = String(repeating: "a", count: 40)
        XCTAssertFalse(iso.needsParent)
    }

    func testValidateRejectsParentOnNonCHD() {
        var project = GameProject()
        project.title = "Parent check"; project.titleID = "SLUS12345"
        project.output = URL(fileURLWithPath: "/tmp/parent-check.pkg")
        var disc = GameDisc(source: URL(fileURLWithPath: "/x/game.iso"), gameID: "SLUS12345")
        disc.chdParent = URL(fileURLWithPath: "/x/parent.chd")
        project.discs = [disc]
        XCTAssertThrowsError(try project.validate())
    }

    func testLegacyGameDiscJSONDecodesWithoutParent() throws {
        let json = """
        {"id":"\(UUID().uuidString)","source":"file:///x/game.iso","gameID":"SLUS12345","configSource":"User-selected local file"}
        """
        let disc = try JSONDecoder().decode(GameDisc.self, from: Data(json.utf8))
        XCTAssertNil(disc.chdParent)
        XCTAssertNil(disc.chdParentSHA1)
        XCTAssertFalse(disc.needsParent)
        var child = disc
        child.source = URL(fileURLWithPath: "/x/child.chd")
        child.chdParentSHA1 = String(repeating: "b", count: 40)
        XCTAssertTrue(child.needsParent)
        XCTAssertEqual(try JSONDecoder().decode(GameDisc.self, from: JSONEncoder().encode(child)).chdParentSHA1,
                        String(repeating: "b", count: 40))
    }

    func testFingerprintBindsParent() {
        func key(parent: String?, path: String?) -> DiscStageKey {
            DiscStageKey(index: 0, sourcePath: "/x/child.chd", sourceSHA256: "s",
                         gameID: "SLUS12345", configSHA256: nil,
                         parentSHA256: parent, parentPath: path)
        }
        func digest(_ key: DiscStageKey) -> String {
            JobFingerprint(appVersion: "1.0.0", helperSHA256: "h", title: "T", titleID: "SLUS12345",
                           contentID: "C", cropArtwork: false, assets: [:], support: [:],
                           discs: [key]).digest
        }
        let plain = digest(key(parent: nil, path: nil))
        XCTAssertNotEqual(plain, digest(key(parent: "p1", path: "/x/p.chd")))
        XCTAssertNotEqual(digest(key(parent: "p1", path: "/x/p.chd")),
                          digest(key(parent: "p2", path: "/x/p.chd")))
        XCTAssertNotEqual(digest(key(parent: "p1", path: "/x/p.chd")),
                          digest(key(parent: "p1", path: "/y/p.chd")))
        XCTAssertEqual(plain, digest(key(parent: nil, path: nil)))
    }

    func testRecoveryMismatchCoversParent() {
        let jobID = UUID()
        func queued(parentSource: String?, parentSHA256: String?) -> QueuedJobIdentity {
            var project = GameProject()
            project.title = "Parent"; project.titleID = "SLUS12345"
            project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
            var disc = GameDisc(source: URL(fileURLWithPath: "/x/child.chd"), gameID: "SLUS12345")
            disc.chdParent = parentSource.map { URL(fileURLWithPath: $0) }
            project.discs = [disc]
            var identity = QueuedJobIdentity(jobID: jobID, project: project)
            identity.discs[0].parentSHA256 = parentSHA256
            return identity
        }
        func record(parentSource: String?, parentSHA256: String?) -> BuildCompletionRecord {
            BuildCompletionRecord(jobID: jobID.uuidString, title: "Parent", titleID: "SLUS12345",
                                  contentID: "UP0001-SLUS12345_00-0000000000000001",
                                  packageSHA256: String(repeating: "a", count: 64),
                                  discs: [QueuedDiscIdentity(gameID: "SLUS12345", source: "/x/child.chd",
                                                             sourceSHA256: "s", configHash: nil,
                                                             parentSource: parentSource, parentSHA256: parentSHA256)],
                                  supportPaths: ["key": "", "rap": "", "logo": "", "card": ""],
                                  assetPaths: ["icon": "", "background": "", "sound": ""],
                                  cropArtwork: false, supportHashes: [:], assetHashes: [:])
        }
        // Legacy parentless records still match parentless jobs.
        XCTAssertNil(queued(parentSource: nil, parentSHA256: nil).mismatch(against: record(parentSource: nil, parentSHA256: nil)))
        // A changed parent path no longer matches.
        let pathChange = queued(parentSource: "/x/other.chd", parentSHA256: "ph").mismatch(
            against: record(parentSource: "/x/parent.chd", parentSHA256: "ph"))
        XCTAssertTrue(pathChange?.contains("disc 1") == true, pathChange ?? "matched unexpectedly")
        // A changed parent hash no longer matches the durable attempt.
        let attempt = BuildAttemptIdentity(attemptID: "a", jobID: jobID.uuidString, buildFingerprint: "f",
                                           title: "Parent", titleID: "SLUS12345",
                                           contentID: "UP0001-SLUS12345_00-0000000000000001",
                                           cropArtwork: false,
                                           discs: [QueuedDiscIdentity(gameID: "SLUS12345", source: "/x/child.chd",
                                                                      sourceSHA256: "s", configHash: nil,
                                                                      parentSource: "/x/parent.chd", parentSHA256: "ph1")],
                                           supportHashes: [:], assetHashes: [:])
        var tampered = record(parentSource: "/x/parent.chd", parentSHA256: "ph2")
        tampered.attemptID = "a"; tampered.buildFingerprint = "f"
        XCTAssertTrue(attempt.mismatch(against: tampered)?.contains("disc 1") == true)
        tampered.discs[0].parentSHA256 = "ph1"
        XCTAssertNil(attempt.mismatch(against: tampered))
    }

    func testProjectRoundTripPreservesParentSelection() throws {
        var project = GameProject()
        project.title = "Parent"
        project.titleID = "SLUS12345"
        project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
        var disc = GameDisc(source: URL(fileURLWithPath: "/x/child.chd"), gameID: "")
        disc.chdParent = URL(fileURLWithPath: "/x/parent.chd")
        disc.chdParentSHA1 = String(repeating: "c", count: 40)
        project.discs = [disc]
        project.output = URL(fileURLWithPath: "/tmp/parent.pkg")
        let decoded = try JSONDecoder().decode(GameProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.discs[0].chdParent, URL(fileURLWithPath: "/x/parent.chd"))
        XCTAssertEqual(decoded.discs[0].chdParentSHA1, String(repeating: "c", count: 40))
        XCTAssertFalse(decoded.discs[0].needsParent)
        // The queued identity carries the parent path (hashes bind at build).
        let queued = QueuedJobIdentity(jobID: UUID(), project: project)
        XCTAssertEqual(queued.discs[0].parentSource, "/x/parent.chd")
        XCTAssertNil(queued.discs[0].parentSHA256)
    }
}
