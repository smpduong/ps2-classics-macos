// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsApp

/// The sidebar candidate label must derive from the bundled release metadata
/// (the same Info.plist the build script stamps from release.json), never
/// from a hardcoded string that freezes on an old candidate.
final class ReleaseIdentityTests: XCTestCase {
    func testFormatsExactCandidateLabel() {
        XCTAssertEqual(ReleaseIdentity.sidebarText(shortVersion: "1.0.0", label: "RC21"),
                       "1.0 RC21 • Release candidate\nIntel + Apple Silicon\nmacOS 12 and later")
    }

    func testFallsBackGenericallyNeverSpecificallyWrong() {
        // Unknown values must degrade to a generic label, never to a stale
        // specific candidate.
        for (version, label) in [(nil, nil), ("", ""), ("1.0.0", nil), (nil, "RC21")] as [(String?, String?)] {
            let text = ReleaseIdentity.sidebarText(shortVersion: version, label: label)
            XCTAssertTrue(text.hasSuffix("Release candidate\nIntel + Apple Silicon\nmacOS 12 and later"), text)
            XCTAssertFalse(text.contains("RC8"), text)
        }
        XCTAssertTrue(ReleaseIdentity.sidebarText(shortVersion: "1.0.0", label: nil).hasPrefix("1.0 RC "))
        XCTAssertTrue(ReleaseIdentity.sidebarText(shortVersion: nil, label: "RC21").hasPrefix("1.0 RC21"))
    }

    func testReadsSyntheticBundleMetadata() throws {
        // A bundle carrying the stamped keys resolves exactly; one without
        // them falls back generically.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(shortVersion: String?, label: String?) throws -> Bundle {
            let dir = root.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var plist: [String: Any] = [:]
            if let shortVersion { plist["CFBundleShortVersionString"] = shortVersion }
            if let label { plist["PS2ReleaseLabel"] = label }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent("Info.plist"), options: .withoutOverwriting)
            return try XCTUnwrap(Bundle(url: dir))
        }
        XCTAssertEqual(ReleaseIdentity.sidebarText(bundle: try bundle(shortVersion: "1.0.0", label: "RC21")),
                       "1.0 RC21 • Release candidate\nIntel + Apple Silicon\nmacOS 12 and later")
        let fallback = ReleaseIdentity.sidebarText(bundle: try bundle(shortVersion: nil, label: nil))
        XCTAssertTrue(fallback.hasPrefix("1.0 RC "), fallback)
        XCTAssertFalse(fallback.contains("RC8"), fallback)
    }
}
