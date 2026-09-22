// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CryptoKit
@testable import PS2ClassicsCore

final class DiscInspectorTests: XCTestCase {
    private func withFile(_ data: Data, name: String = "disc.iso", _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        try body(url)
    }

    private func fixture(pvdSector: Int = 16) -> Data {
        var data = Data(repeating: 0, count: 24 * 2048)
        for sector in 16...pvdSector {
            let offset = sector * 2048
            data[offset] = sector == pvdSector ? 1 : 0
            data.replaceSubrange((offset + 1)..<(offset + 6), with: Data("CD001".utf8))
            data[offset + 6] = 1
        }
        let offset = pvdSector * 2048
        data.replaceSubrange((offset + 40)..<(offset + 72), with: Data("SYNTHETIC TEST".padding(toLength: 32, withPad: " ", startingAt: 0).utf8))
        data[offset + 80] = 24
        data[offset + 87] = 24
        data[offset + 129] = 8
        data[offset + 130] = 8
        return data
    }

    func testValidDescriptorAndUnicodePathPreserveSourceHash() throws {
        try withFile(fixture(), name: "小さい DVD café.iso") { url in
            let before = SHA256.hash(data: try Data(contentsOf: url))
            let result = try DiscInspector.inspect(url)
            XCTAssertEqual(result.volumeLabel, "SYNTHETIC TEST")
            XCTAssertEqual(result.declaredVolumeBytes, 24 * 2048)
            XCTAssertTrue(result.notes.contains { $0.contains("cannot be established") })
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
        }
    }

    func testPrimaryDescriptorAfterBootDescriptor() throws {
        try withFile(fixture(pvdSector: 17)) { url in
            XCTAssertEqual(try DiscInspector.inspect(url).volumeLabel, "SYNTHETIC TEST")
        }
    }

    func testEachInconsistentFieldFailsIndependently() throws {
        for relativeOffset in [80, 87, 129, 130] {
            var data = fixture()
            data[16 * 2048 + relativeOffset] ^= 1
            try withFile(data) { url in
                let before = SHA256.hash(data: try Data(contentsOf: url))
                XCTAssertThrowsError(try DiscInspector.inspect(url))
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
            }
        }
    }

    func testTruncatedVolumeRejected() throws {
        try withFile(Data(fixture().prefix(17 * 2048))) { url in
            XCTAssertThrowsError(try DiscInspector.inspect(url))
        }
    }

    func testExtensionIsNotEvidenceOfFormat() throws {
        try withFile(Data(repeating: 7, count: 40_000)) { url in
            XCTAssertEqual(try DiscInspector.inspect(url).format, "Unrecognized by this inspector")
        }
    }

    func testEmptyAndMissingInputsFail() throws {
        try withFile(Data()) { url in XCTAssertThrowsError(try DiscInspector.inspect(url)) }
        XCTAssertThrowsError(try DiscInspector.inspect(URL(fileURLWithPath: "/missing-\(UUID().uuidString).iso")))
        XCTAssertThrowsError(try DiscInspector.inspect(FileManager.default.temporaryDirectory))
    }

    func testTruncatedCHDRejected() throws {
        try withFile(Data("MComprHD".utf8), name: "test.chd") { url in
            XCTAssertThrowsError(try DiscInspector.inspect(url))
        }
    }

    func testTrailingBytesAreReported() throws {
        var data = fixture()
        data.append(Data(repeating: 0, count: 2048))
        try withFile(data) { url in
            XCTAssertTrue(try DiscInspector.inspect(url).notes.contains { $0.contains("Bytes follow") })
        }
    }
}
