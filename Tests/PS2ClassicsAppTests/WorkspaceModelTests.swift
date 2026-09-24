// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import PS2ClassicsCore
@testable import PS2ClassicsApp

/// Image-tools inspection guidance: an unrecognized file in decrypt mode may
/// be a sealed CEX image, so the UI must point at Detect profile instead of
/// leaving the generic "not supported" inspector text standing alone.
@MainActor
final class WorkspaceModelTests: XCTestCase {
    private func inspection(supported: Bool) throws -> DiscInspection {
        let declared = supported ? "\"declaredVolumeBytes\":100," : ""
        let format = supported ? "ISO 9660 descriptor" : "Unrecognized by this inspector"
        let json = "{\"filename\":\"x.iso\",\"byteCount\":100,\"format\":\"\(format)\",\(declared)\"notes\":[],\"requiresParent\":false}"
        return try JSONDecoder().decode(DiscInspection.self, from: Data(json.utf8))
    }

    func testDecryptModeGuidesUnrecognizedFiles() throws {
        let guidance = try XCTUnwrap(WorkspaceModel.decryptModeNotice(action: .decrypt,
                                                                      inspection: try inspection(supported: false)))
        XCTAssertTrue(guidance.contains("Detect profile"), guidance)
        XCTAssertTrue(guidance.contains("decrypt or verify"), guidance)
    }

    func testNoGuidanceOtherwise() throws {
        XCTAssertNil(WorkspaceModel.decryptModeNotice(action: .encrypt, inspection: try inspection(supported: false)))
        XCTAssertNil(WorkspaceModel.decryptModeNotice(action: .decrypt, inspection: try inspection(supported: true)))
        XCTAssertNil(WorkspaceModel.decryptModeNotice(action: .decrypt, inspection: nil))
    }
}
