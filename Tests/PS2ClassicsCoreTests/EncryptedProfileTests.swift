// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class EncryptedProfileTests: XCTestCase {
    private let contentID = "UP0001-SLUS12345_00-0000000000000001"

    func testProfileFollowsDiscNumber() {
        XCTAssertEqual(EncryptedProfile.forDisc(1), "ISO.BIN.ENC")
        XCTAssertEqual(EncryptedProfile.forDisc(2), "ISO.BIN.ENC2")
        XCTAssertEqual(EncryptedProfile.forDisc(9), "ISO.BIN.ENC9")
        XCTAssertEqual(EncryptedProfile.forDisc(0), "ISO.BIN.ENC")
        XCTAssertEqual(EncryptedProfile.forDisc(10), "ISO.BIN.ENC")
    }

    func testOnlyDocumentedProfilesAreSupported() {
        XCTAssertEqual(EncryptedProfile.allNames.count, 18)
        for name in EncryptedProfile.allNames { XCTAssertTrue(EncryptedProfile.isSupported(name), name) }
        for bad in ["", "ISO.BIN.ENC0", "ISO.BIN.ENC10", "iso.bin.enc", "ISO.BIN.ENC ",
                    "CONFIG0", "CONFIG10", "config", "ISO.BIN.ENC2 "] {
            XCTAssertFalse(EncryptedProfile.isSupported(bad), bad)
        }
    }

    func testRequestBuildsNumberedDecryptArguments() throws {
        let request = ConversionRequest(action: .decrypt,
                                        source: URL(fileURLWithPath: "/in/x.enc"),
                                        destination: URL(fileURLWithPath: "/out/x.iso"),
                                        keyFile: URL(fileURLWithPath: "/k"),
                                        contentID: contentID, discNumber: 2)
        XCTAssertEqual(request.logicalName, "ISO.BIN.ENC2")
        XCTAssertEqual(try request.arguments(),
                       ["decrypt", "/in/x.enc", "/out/x.iso", "/k", "2", "ISO.BIN.ENC2"])
    }

    func testRequestBuildsEncryptArgumentsWithExplicitProfile() throws {
        let request = ConversionRequest(action: .encrypt,
                                        source: URL(fileURLWithPath: "/in/x.iso"),
                                        destination: URL(fileURLWithPath: "/out/x.enc"),
                                        keyFile: URL(fileURLWithPath: "/k"),
                                        contentID: contentID, discNumber: 1,
                                        logicalName: "ISO.BIN.ENC")
        XCTAssertEqual(try request.arguments(),
                       ["encrypt-iso", "/in/x.iso", "/out/x.enc", "/k", contentID, "1", "ISO.BIN.ENC"])
    }

    func testExpandedCHDSourceOverridesRequestSource() throws {
        // A CHD is expanded first; the helper must encrypt the expanded image,
        // not the original CHD path.
        let request = ConversionRequest(action: .encrypt,
                                        source: URL(fileURLWithPath: "/in/x.chd"),
                                        destination: URL(fileURLWithPath: "/out/x.enc"),
                                        keyFile: URL(fileURLWithPath: "/k"),
                                        contentID: contentID, discNumber: 1)
        XCTAssertEqual(try request.arguments(source: URL(fileURLWithPath: "/tmp/expanded.image")),
                       ["encrypt-iso", "/tmp/expanded.image", "/out/x.enc", "/k", contentID, "1", "ISO.BIN.ENC"])
        XCTAssertEqual(try request.arguments()[1], "/in/x.chd")
    }

    func testRequestRejectsBadDiscProfileAndContentID() {
        let base = { (disc: Int, logical: String?, cid: String) in
            ConversionRequest(action: .encrypt, source: URL(fileURLWithPath: "/i"),
                              destination: URL(fileURLWithPath: "/o"), keyFile: URL(fileURLWithPath: "/k"),
                              contentID: cid, discNumber: disc, logicalName: logical)
        }
        XCTAssertThrowsError(try base(0, nil, contentID).arguments())
        XCTAssertThrowsError(try base(10, nil, contentID).arguments())
        XCTAssertThrowsError(try base(1, "ISO.BIN.ENC10", contentID).arguments())
        XCTAssertThrowsError(try base(1, nil, "not-a-content-id").arguments())
        XCTAssertThrowsError(try base(1, nil, "").arguments())
    }
}
