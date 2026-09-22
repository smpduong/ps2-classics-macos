// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A saved, reusable set of support files. Choosing one folder never proves the
/// assets match cryptographically; a profile records only paths, the content ID
/// and whether the files were imported together, and validates presence/size on use.
public struct NamedSupportProfile: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var key: URL?
    public var rap: URL?
    public var logo: URL?
    public var card: URL?
    public var contentID: String
    public var importedTogether: Bool
    /// Real folder the set was imported from, or nil when the files were
    /// picked individually. Never fabricated.
    public var sourceFolder: String?
    public var createdAt: Date

    public init(name: String, support: SupportFiles) {
        self.name = name
        self.key = support.key; self.rap = support.rap
        self.logo = support.logo; self.card = support.card
        self.contentID = support.contentID
        self.importedTogether = support.sourceFolder != nil
        self.sourceFolder = support.sourceFolder?.path
        self.createdAt = Date()
    }

    public var support: SupportFiles {
        var files = SupportFiles()
        files.key = key; files.rap = rap; files.logo = logo; files.card = card
        files.contentID = contentID
        files.sourceFolder = sourceFolder.map { URL(fileURLWithPath: $0) }
        return files
    }
}

public final class SupportProfileStore {
    public private(set) var profiles: [NamedSupportProfile]
    private let url: URL

    public init(url: URL) {
        self.url = url
        if let data = try? BoundedFile.read(url, maximum: 4 * 1024 * 1024),
           let decoded = try? JSONDecoder().decode([NamedSupportProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
    }

    @discardableResult
    public func add(name: String, support: SupportFiles) throws -> NamedSupportProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else {
            throw ConversionFailure(message: "Enter a profile name of 1–64 characters.")
        }
        guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw ConversionFailure(message: "A profile named \(trimmed) already exists. Choose another name.")
        }
        let profile = NamedSupportProfile(name: trimmed, support: support)
        profiles.append(profile)
        try save()
        return profile
    }

    public func remove(id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: [.atomic])
    }

    /// Presence, type, readability and size checks before a profile is applied,
    /// so a moved, unreadable or wrong-sized file is reported instead of
    /// failing mid-build. Readable regular files only — never directories,
    /// symlinks or other special files.
    public func validate(_ profile: NamedSupportProfile) -> [String] {
        var problems = [String]()
        func check(_ url: URL?, _ label: String, _ bytes: Int?) {
            guard let url = url, url.isFileURL else { problems.append("\(label) is not set"); return }
            guard FileManager.default.fileExists(atPath: url.path) else { problems.append("\(label) is missing: \(url.lastPathComponent)"); return }
            guard FileManager.default.isReadableFile(atPath: url.path) else { problems.append("\(label) is not readable: \(url.lastPathComponent)"); return }
            // lstat (not a symlink) plus a regular-file type: neither a
            // directory, a symlink, nor any other special file is accepted.
            guard FileIdentity.of(url)?.isSymbolicLink == false else {
                problems.append("\(label) is not a regular file: \(url.lastPathComponent)"); return
            }
            // attributesOfItem is not cached, unlike URL.resourceValues.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType, type == .typeRegular else {
                problems.append("\(label) is not a regular file: \(url.lastPathComponent)"); return
            }
            if let expected = bytes {
                let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
                if size != expected { problems.append("\(label) is \(size) bytes, expected \(expected)") }
            }
        }
        check(profile.key, "klicensee", 16)
        check(profile.rap, "RAP", 16)
        check(profile.logo, "PS3LOGO.DAT", nil)
        check(profile.card, "blank memory card", nil)
        if profile.contentID.count != 36 { problems.append("content ID is not 36 characters") }
        return problems
    }
}
