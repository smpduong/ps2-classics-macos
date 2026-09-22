// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

public struct GameDisc: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var source: URL
    public var gameID: String
    public var config: URL?
    public var configHash: String?
    public var configSource = "User-selected local file"
    public init(source: URL, gameID: String = "") { self.source = source; self.gameID = gameID }
}

public struct SupportFiles: Codable, Equatable, Sendable {
    public var key: URL?
    public var rap: URL?
    public var logo: URL?
    public var card: URL?
    public var contentID = ""
    /// Folder the current set was imported from, if the files arrived together.
    /// Cleared whenever a file is picked individually, so mixed sets are visible.
    public var sourceFolder: URL?
    public init() {}
    public mutating func importFolder(_ url: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        key = files.first { ["klic.bin", "klicensee.bin", "klicensee.key"].contains($0.lastPathComponent.lowercased()) }
        let raps = files.filter { $0.pathExtension.lowercased() == "rap" }
        rap = raps.count == 1 ? raps[0] : nil
        contentID = ""
        logo = files.first { $0.lastPathComponent.uppercased() == "PS3LOGO.DAT" }
        card = files.first { $0.lastPathComponent.uppercased() == "SCEVMC0.VMC" }
        if let rap = rap, rap.deletingPathExtension().lastPathComponent.count == 36 {
            contentID = rap.deletingPathExtension().lastPathComponent
        }
        let idFile = url.appendingPathComponent("content-id.txt")
        if FileManager.default.fileExists(atPath: idFile.path) {
            contentID = try String(contentsOf: idFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        sourceFolder = url
    }
    public var mixedSelection: Bool { sourceFolder == nil && (key != nil || rap != nil || logo != nil || card != nil) }
    public var missing: [String] {
        var result = [String]()
        if key == nil { result.append("klicensee") }; if rap == nil { result.append("RAP") }
        if logo == nil { result.append("PS3LOGO.DAT") }; if card == nil { result.append("blank memory card") }
        if contentID.count != 36 { result.append("content ID") }; return result
    }
    /// Non-blocking early warnings. Build-time validation stays strict;
    /// these explain mismatches before a long job starts.
    public func diagnostics() -> [String] {
        var warnings = [String]()
        if let key = key {
            if ["rap", "rif"].contains(key.pathExtension.lowercased()) {
                warnings.append("The klicensee points at a RAP/RIF file (\(key.lastPathComponent)). Select the matching 16-byte binary key instead.")
            } else if let size = (try? key.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size != 16 {
                warnings.append("The klicensee is \(size) bytes; a binary klicensee must be exactly 16 bytes.")
            }
        }
        if let rap = rap {
            if let size = (try? rap.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size != 16 {
                warnings.append("The RAP file is \(size) bytes; the title-record RAP must be exactly 16 bytes.")
            }
            let stem = rap.deletingPathExtension().lastPathComponent
            if stem.count == 36, stem != contentID {
                warnings.append("The RAP filename suggests content ID \(stem), but the entered content ID is \(contentID.isEmpty ? "empty" : contentID). Builds use the entered value.")
            }
        }
        if mixedSelection {
            warnings.append("Mixed selection: support files were picked individually rather than as one imported set. Confirm they belong to the same content ID.")
        }
        return warnings
    }
}

public struct GameProject: Codable, Equatable, Sendable {
    public var version = 1
    public var title = ""
    public var titleID = ""
    public var discs: [GameDisc] = []
    public var support = SupportFiles()
    public var icon: URL?
    public var background: URL?
    public var sound: URL?
    public var cropArtwork = false
    public var output: URL?
    public init() {}
    public func validate() throws {
        guard version == 1 else { throw ConversionFailure(message: "This project version is not supported.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 127,
              !title.contains("\0") else { throw ConversionFailure(message: "Enter a title of 1–127 UTF-8 bytes.") }
        guard Self.validGameID(titleID), (1...9).contains(discs.count), discs.allSatisfy({ Self.validGameID($0.gameID) }) else {
            throw ConversionFailure(message: "Add 1–9 discs and enter each nine-character game ID (for example SLUS12345).")
        }
        guard support.missing.isEmpty else { throw ConversionFailure(message: "Setup needs: " + support.missing.joined(separator: ", ")) }
        guard support.contentID.range(of: #"^[A-Z0-9]{6}-[A-Z0-9]{9}_[A-Z0-9]{2}-[A-Z0-9]{16}$"#, options: .regularExpression) != nil else {
            throw ConversionFailure(message: "Enter the content ID that matches your support files.")
        }
        guard let output = output, output.isFileURL else { throw ConversionFailure(message: "Choose a package destination.") }
        guard output.path.utf8.count <= DestinationCheck.maxPathBytes else { throw ConversionFailure(message: "The package destination path is too long for the helper's temporary files. Choose a shorter filename or a shallower folder.") }
        for component in output.pathComponents where component.utf8.count > DestinationCheck.maxComponentBytes {
            throw ConversionFailure(message: "A folder or file name in the destination is longer than \(DestinationCheck.maxComponentBytes) bytes and will not work on common filesystems. Shorten it.")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ConversionFailure(message: "The package destination already exists. Choose a new filename.") }
    }
    public static func validGameID(_ text: String) -> Bool {
        text.range(of: #"^[A-Z]{4}[0-9]{5}$"#, options: .regularExpression) != nil
    }
}

public enum FileDigest {
    public static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256(_ url: URL, cancelled: () throws -> Void = {}, progress: ((UInt64, UInt64) -> Void)? = nil) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var info = stat()
        let total: UInt64
        if fstat(file.fileDescriptor, &info) == 0, info.st_size > 0 {
            total = UInt64(info.st_size)
        } else {
            total = 0
        }
        var done: UInt64 = 0
        var hash = SHA256()
        while true {
            let finished = try autoreleasepool { () throws -> Bool in
                try cancelled()
                let data = try file.read(upToCount: 8 * 1024 * 1024) ?? Data()
                if data.isEmpty { return true }
                hash.update(data: data)
                done += UInt64(data.count)
                progress?(done, total)
                return false
            }
            if finished { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func small(_ url: URL, maximum: Int) throws -> Data {
        guard url.isFileURL else { throw ConversionFailure(message:"Choose a local file.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximum else {
            throw ConversionFailure(message: "Unsupported or oversized support file: \(url.lastPathComponent)")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count == size else { throw ConversionFailure(message: "Support file changed while reading.") }
        return data
    }
}

public enum DiscInput {
    /// A CUE is accepted only when its complete layout describes one data track
    /// at zero. Unsupported layouts are rejected with a specific reason rather
    /// than a generic failure, so the user knows exactly what is not handled.
    public static func resolve(_ url: URL) throws -> URL {
        guard url.pathExtension.lowercased() == "cue" else { return url }
        let text = String(decoding: try FileDigest.small(url, maximum: 65536), as: UTF8.self)
        var file: String?
        var trackSeen = false
        var indexSeen = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("REM ") { continue }
            if upper.hasPrefix("FILE") {
                guard let name = quotedName(line) else {
                    throw ConversionFailure(message: "The CUE has a FILE line without a quoted filename.")
                }
                guard upper.hasSuffix("BINARY") else {
                    throw ConversionFailure(message: "Only BINARY CUE images are supported; a FILE line must name a BIN and end with BINARY.")
                }
                guard file == nil else {
                    throw ConversionFailure(message: "This CUE references more than one file. Multi-file CUE layouts are not supported; provide a single BIN image.")
                }
                file = name
                continue
            }
            if upper.hasPrefix("TRACK") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3 else { throw ConversionFailure(message: "The CUE has a malformed TRACK line: \(line.prefix(60))") }
                let number = String(parts[1])
                let mode = String(parts[2]).uppercased()
                if mode.contains("AUDIO") {
                    throw ConversionFailure(message: "Track \(number) is an audio track. Audio and mixed-track CUEs are not supported; only one data track is handled.")
                }
                guard mode == "MODE1/2352" || mode == "MODE2/2352" else {
                    throw ConversionFailure(message: "Track \(number) uses \(mode). Only MODE1/2352 and MODE2/2352 data tracks are supported.")
                }
                guard !trackSeen, number == "01" else {
                    throw ConversionFailure(message: "This CUE has more than one data track. Multi-track CUEs are not supported.")
                }
                trackSeen = true
                continue
            }
            if upper.hasPrefix("INDEX") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3 else { throw ConversionFailure(message: "The CUE has a malformed INDEX line: \(line.prefix(60))") }
                let indexNumber = String(parts[1])
                let time = String(parts[2])
                if indexNumber == "00" {
                    throw ConversionFailure(message: "This CUE defines a pregap (INDEX 00). Pregaps and hidden audio are not supported.")
                }
                guard indexNumber == "01" else {
                    throw ConversionFailure(message: "Unsupported INDEX \(indexNumber) in this CUE; only INDEX 01 is handled.")
                }
                guard time == "00:00:00" else {
                    throw ConversionFailure(message: "Track 01 starts at \(time). Only a data track starting at 00:00:00 is supported.")
                }
                indexSeen = true
                continue
            }
            if upper.hasPrefix("PREGAP") { throw ConversionFailure(message: "This CUE defines a PREGAP directive. Pregaps are not supported.") }
            if upper.hasPrefix("POSTGAP") { throw ConversionFailure(message: "This CUE defines a POSTGAP directive. Postgaps are not supported.") }
            if upper.hasPrefix("CATALOG") || upper.hasPrefix("TITLE") || upper.hasPrefix("PERFORMER") || upper.hasPrefix("SONGWRITER") || upper.hasPrefix("ISRC") {
                continue // informational only; does not change the track layout
            }
            throw ConversionFailure(message: "Unsupported CUE line: \(line.prefix(60))")
        }
        guard let file = file, trackSeen, indexSeen, !file.hasPrefix("/"), !file.contains("\\"), !file.split(separator: "/").contains("..") else {
            throw ConversionFailure(message: "The CUE needs one relative BIN filename and a data track at 00:00:00.")
        }
        return url.deletingLastPathComponent().appendingPathComponent(file)
    }

    private static func quotedName(_ line: String) -> String? {
        guard let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last else { return nil }
        return String(line[line.index(after: first)..<last])
    }
}
