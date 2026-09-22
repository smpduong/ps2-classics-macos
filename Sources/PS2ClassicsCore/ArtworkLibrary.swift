// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ImageIO
import AppKit

/// A locally found artwork image offered as an optional convenience. Nothing is
/// applied automatically: the user previews and explicitly accepts a candidate.
public struct ArtworkCandidate: Identifiable, Sendable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let relativePath: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public var dimensions: String { "\(pixelWidth)×\(pixelHeight)" }
    public init(url: URL, relativePath: String, pixelWidth: Int, pixelHeight: Int) {
        self.url = url; self.relativePath = relativePath
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

/// Finds local artwork files that name an exact game ID, for optional
/// icon/background convenience. This is a bounded, read-only folder scan: it
/// never downloads anything, never rewrites a user's image, and never selects
/// artwork on the user's behalf.
public enum ArtworkLibrary {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
    /// Reject absurd images before decoding so a folder cannot exhaust memory.
    public static let maxPixelDimension = 8192
    public static let maxCandidates = 100
    public static let maxScanned = 50000

    /// Normalizes a filename stem for matching: uppercase, ASCII letters and
    /// digits only. `SLUS_208.92_icon` becomes `SLUS20892ICON`.
    static func normalized(_ stem: String) -> String {
        stem.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// True when the normalized filename names this exact game ID and the ID is
    /// not merely a prefix of a longer numeric run (`SLUS208921` must not match
    /// `SLUS20892`).
    static func matches(_ stem: String, gameID: String) -> Bool {
        let name = normalized(stem)
        let id = normalized(gameID)
        guard !id.isEmpty, let range = name.range(of: id) else { return false }
        guard range.lowerBound == name.startIndex else { return false }
        let next = name[range.upperBound...].first
        return next == nil || !next!.isNumber
    }

    public static func candidates(for gameID: String, in root: URL) throws -> [ArtworkCandidate] {
        guard GameProject.validGameID(gameID), root.isFileURL else {
            throw ConversionFailure(message: "Choose a local artwork folder and a valid disc ID.")
        }
        let status = ConfigLibrary.availability(of: root)
        guard status.isUsable else { throw ConversionFailure(message: ConfigLibrary.describe(status, folder: root)) }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var enumerationError: Error?
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ConversionFailure(message: "Cannot read the artwork folder.")
        }
        var scanned = 0
        var results = [ArtworkCandidate]()
        for case let url as URL in files {
            scanned += 1
            guard scanned <= maxScanned else { throw ConversionFailure(message: "The selected folder is too large. Choose the artwork folder itself.") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true, imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard matches(url.deletingPathExtension().lastPathComponent, gameID: gameID) else { continue }
            guard let size = pixelSize(of: url) else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            results.append(ArtworkCandidate(url: url, relativePath: relative,
                                            pixelWidth: size.width, pixelHeight: size.height))
            guard results.count <= maxCandidates else { throw ConversionFailure(message: "More than \(maxCandidates) matching images. Choose a narrower artwork folder.") }
        }
        if let error = enumerationError { throw error }
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Reads only the image header for dimensions; the full image is not
    /// decoded here. Oversized or non-image files are skipped.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxPixelDimension, height <= maxPixelDimension else { return nil }
        return (width, height)
    }

    /// A bounded-size preview, so a large candidate cannot use much memory just
    /// to be shown in a list.
    public static func thumbnail(of url: URL, maxPixel: Int = 256) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
