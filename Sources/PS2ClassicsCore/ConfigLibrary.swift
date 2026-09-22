// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

public struct ConfigCandidate: Identifiable, Sendable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let relativePath: String
    public let sha256: String
    /// File metadata shown so a user can judge provenance before selecting.
    public let byteCount: Int?
    public let modified: Date?
    public init(url: URL, relativePath: String, sha256: String, byteCount: Int? = nil, modified: Date? = nil) {
        self.url = url; self.relativePath = relativePath; self.sha256 = sha256
        self.byteCount = byteCount; self.modified = modified
    }
}

public enum ConfigLibrary {
    /// Whether a saved library folder can currently be used. A missing or
    /// unreadable folder must be reported plainly rather than looking like an
    /// empty library or losing the user's selection.
    public enum Availability: Equatable, Sendable {
        case notSelected
        case available
        case missing
        case notADirectory
        case unreadable

        public var isUsable: Bool { self == .available }
    }

    public static func availability(of root: URL?) -> Availability {
        guard let root = root else { return .notSelected }
        guard root.isFileURL else { return .notADirectory }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notADirectory }
        return FileManager.default.isReadableFile(atPath: root.path) ? .available : .unreadable
    }

    /// Plain-language status for the interface.
    public static func describe(_ availability: Availability, folder: URL?) -> String {
        switch availability {
        case .notSelected: return "No local CONFIG library selected."
        case .available: return folder?.path ?? "Selected"
        case .missing: return "The selected CONFIG library is missing or disconnected. Reconnect it, choose it again, or clear the selection. Your projects are unaffected."
        case .notADirectory: return "The selected CONFIG library is not a folder. Choose a folder that contains your CONFIG files."
        case .unreadable: return "The selected CONFIG library cannot be read. Check its permissions, choose it again, or clear the selection."
        }
    }

    public static func candidates(for gameID: String, in root: URL) throws -> [ConfigCandidate] {
        guard GameProject.validGameID(gameID), root.isFileURL else { throw ConversionFailure(message:"Choose a local CONFIG folder and a valid disc ID.") }
        let status = availability(of: root)
        guard status.isUsable else { throw ConversionFailure(message: describe(status, folder: root)) }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var enumerationError: Error?
        guard let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey],options:[.skipsHiddenFiles],errorHandler:{_,error in enumerationError=error;return false}) else { throw ConversionFailure(message:"Cannot read the CONFIG folder.") }
        var scanned=0,results=[ConfigCandidate]()
        for case let url as URL in files {
            scanned += 1
            guard scanned <= 50000 else { throw ConversionFailure(message:"The selected folder is too large. Choose the CONFIG library itself.") }
            let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey])
            if values.isSymbolicLink==true { continue }
            guard values.isRegularFile==true, url.pathExtension.uppercased()=="CONFIG" else { continue }
            let normalized=url.deletingPathExtension().lastPathComponent.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            guard normalized==gameID else { continue }
            let bytes=try FileDigest.small(url,maximum:1024*1024)
            if bytes.prefix(4)==Data([80,83,50,0]) || bytes.prefix(4)==Data([78,80,68,0]) { continue }
            let hash=SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
            let relative=String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count)).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            results.append(ConfigCandidate(url:url,relativePath:relative,sha256:hash,
                                           byteCount: values.fileSize, modified: values.contentModificationDate))
            guard results.count<=100 else { throw ConversionFailure(message:"More than 100 matching CONFIGs. Choose a narrower library folder.") }
        }
        if let error=enumerationError { throw error }
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
