// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PS2ClassicsCore

final class ArtworkLibraryTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @discardableResult
    private func writePNG(_ url: URL, width: Int, height: Int) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionFailure(message: "could not create test image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailure(message: "could not write test image") }
        return url
    }

    func testExactGameIDMatchingAndDimensions() throws {
        try temporary { folder in
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("covers"), withIntermediateDirectories: true)
            try writePNG(folder.appendingPathComponent("SLUS20892.png"), width: 320, height: 176)
            try writePNG(folder.appendingPathComponent("covers/SLUS_208.92_icon.jpg"), width: 64, height: 64)
            try writePNG(folder.appendingPathComponent("SLUS208921.png"), width: 10, height: 10)   // longer numeric run: not a match
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("SLUS20892.txt"))            // wrong extension
            let matches = try ArtworkLibrary.candidates(for: "SLUS20892", in: folder)
            XCTAssertEqual(Set(matches.map(\.relativePath)), Set(["SLUS20892.png", "covers/SLUS_208.92_icon.jpg"]))
            let first = try XCTUnwrap(matches.first { $0.relativePath == "SLUS20892.png" })
            XCTAssertEqual(first.pixelWidth, 320)
            XCTAssertEqual(first.pixelHeight, 176)
            XCTAssertEqual(first.dimensions, "320×176")
            XCTAssertTrue(try ArtworkLibrary.candidates(for: "SLUS21133", in: folder).isEmpty)
        }
    }

    func testOversizedAndSymlinkedImagesAreSkipped() throws {
        try temporary { folder in
            try writePNG(folder.appendingPathComponent("SLUS20892.png"), width: 9000, height: 4) // over the dimension cap
            let real = folder.appendingPathComponent("real.png")
            try writePNG(real, width: 32, height: 32)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("SLUS20892-link.png"), withDestinationURL: real)
            let matches = try ArtworkLibrary.candidates(for: "SLUS20892", in: folder)
            XCTAssertTrue(matches.isEmpty, "oversized and symlinked images must not be offered")
        }
    }

    func testMissingFolderIsAClearError() throws {
        try temporary { folder in
            XCTAssertThrowsError(try ArtworkLibrary.candidates(for: "SLUS20892", in: folder.appendingPathComponent("gone"))) { error in
                XCTAssertTrue(error.localizedDescription.contains("missing or disconnected"), error.localizedDescription)
            }
            XCTAssertThrowsError(try ArtworkLibrary.candidates(for: "bad-id", in: folder))
        }
    }
}
