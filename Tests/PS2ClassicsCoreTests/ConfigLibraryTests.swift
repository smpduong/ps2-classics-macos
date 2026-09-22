// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class ConfigLibraryTests: XCTestCase {
    func testExactIDAlternativesAndFingerprint() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for name in ["CUSTOM","NET"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true) }
        let first=root.appendingPathComponent("CUSTOM/SLUS_208.92.CONFIG")
        let bytes=Data([0,0,0,0,1,2,3,4]);try bytes.write(to:first)
        try Data([9,8,7]).write(to:root.appendingPathComponent("NET/SLUS20892.CONFIG"))
        try bytes.write(to:root.appendingPathComponent("SLUS208921.CONFIG"))
        try Data([80,83,50,0,1]).write(to:root.appendingPathComponent("SLUS-20892.CONFIG"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("SLUS_20892.CONFIG"),withDestinationURL:first)
        let matches=try ConfigLibrary.candidates(for:"SLUS20892",in:root)
        XCTAssertEqual(matches.map(\.relativePath),["CUSTOM/SLUS_208.92.CONFIG","NET/SLUS20892.CONFIG"])
        XCTAssertEqual(matches[0].sha256,FileDigest.sha256(data:bytes))
        XCTAssertEqual(matches[0].byteCount, bytes.count, "candidate metadata must be reported for provenance")
        XCTAssertNotNil(matches[0].modified)
        XCTAssertTrue(try ConfigLibrary.candidates(for:"SLUS21133",in:root).isEmpty)
        XCTAssertThrowsError(try ConfigLibrary.candidates(for:"../../bad",in:root))
    }

    func testAvailabilityDistinguishesMissingAndWrongType() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertEqual(ConfigLibrary.availability(of:nil), .notSelected)
        XCTAssertEqual(ConfigLibrary.availability(of:root), .available)
        XCTAssertEqual(ConfigLibrary.availability(of:root.appendingPathComponent("gone")), .missing)
        let file=root.appendingPathComponent("notafolder")
        try Data([1]).write(to:file)
        XCTAssertEqual(ConfigLibrary.availability(of:file), .notADirectory)
        // A missing library is a clear, non-fatal error — never a crash and
        // never treated as an empty library.
        XCTAssertThrowsError(try ConfigLibrary.candidates(for:"SLUS20892",in:root.appendingPathComponent("gone"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing or disconnected"), error.localizedDescription)
        }
        XCTAssertTrue(ConfigLibrary.describe(.missing, folder: root).contains("Reconnect"))
        XCTAssertTrue(ConfigLibrary.describe(.available, folder: root).contains(root.lastPathComponent))
    }
}
