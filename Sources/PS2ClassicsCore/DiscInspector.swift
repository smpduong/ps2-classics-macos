// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum MediaChoice: String, CaseIterable, Codable, Sendable {
    case auto = "Auto", cd = "CD", dvd = "DVD"
}

public struct DiscInspection: Codable, Sendable {
    public let filename: String
    public let byteCount: UInt64
    public let format: String
    public let volumeLabel: String?
    public let declaredVolumeBytes: UInt64?
    public let notes: [String]
    public var gameID: String? = nil
    public var expandedByteCount: UInt64? = nil
    /// Set when a CHD stores differences against a parent that was not
    /// supplied. `expandedByteCount` stays nil, so the image still counts as
    /// unsupported until the exact parent is chosen.
    public var requiresParent: Bool = false
    /// Lowercase parent SHA-1 declared by the child header, for display.
    public var parentSHA1: String? = nil
    public var isSupported: Bool { declaredVolumeBytes != nil || expandedByteCount != nil }
}

public enum InspectionError: LocalizedError {
    case notRegularFile
    case emptyFile
    case malformedISO(String)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile: return "Choose a regular disc image file."
        case .emptyFile: return "The selected file is empty."
        case .malformedISO(let reason): return "ISO inspection stopped: \(reason)"
        }
    }
}

/// Bounded, read-only format inspection. This does not certify a PS2 disc,
/// its physical CD/DVD medium, its file tree, or its payload integrity.
public enum DiscInspector {
    public static func inspect(_ input: URL, parent: URL? = nil, helper: URL? = nil, runner: ConversionRunner? = nil) throws -> DiscInspection {
        let url = try DiscInput.resolve(input)
        if url.pathExtension.lowercased() == "chd" { return try CHDImporter.inspect(url, parent: parent, helper: helper, runner: runner) }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard info.isRegularFile == true else { throw InspectionError.notRegularFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { throw InspectionError.emptyFile }
        var notes = ["CD/DVD type cannot be established from file size or an ISO header alone.",
                     "Inspection does not verify game compatibility or image integrity."]
        if ["cue", "chd"].contains(url.pathExtension.lowercased()) {
            return DiscInspection(filename: url.lastPathComponent, byteCount: size,
                format: "Not inspected (\(url.pathExtension.uppercased()))", volumeLabel: nil,
                declaredVolumeBytes: nil, notes: notes + ["This input requires a backend that is not integrated yet."])
        }
        var stride = 2048, userOffset = 0
        for layout in [(2048,0),(2352,16),(2352,24)] where size >= UInt64(17*layout.0) {
            try handle.seek(toOffset:UInt64(16*layout.0+layout.1))
            let probe = try handle.read(upToCount:7) ?? Data()
            if probe.count == 7, probe[1..<6] == Data("CD001".utf8) { stride = layout.0; userOffset = layout.1; break }
        }
        // ECMA-119: volume descriptors start at logical sector 16.
        // Bound scanning to 64 descriptors; do not allocate in proportion to image size.
        for sector in 16..<80 {
            let offset = UInt64(sector * stride + userOffset)
            guard offset + 2048 <= size else { break }
            try handle.seek(toOffset: offset)
            let descriptor = try handle.read(upToCount: 2048) ?? Data()
            guard descriptor.count == 2048 else {
                throw InspectionError.malformedISO("the file changed or a descriptor was truncated.")
            }
            guard descriptor.subdata(in: 1..<6) == Data("CD001".utf8) else { break }
            guard descriptor[6] == 1 else {
                throw InspectionError.malformedISO("unsupported descriptor version.")
            }
            if descriptor[0] == 255 { break }
            guard descriptor[0] == 1 else { continue }
            let blocksLE = integer(descriptor, at: 80, count: 4, littleEndian: true)
            let blocksBE = integer(descriptor, at: 84, count: 4, littleEndian: false)
            let blockSizeLE = integer(descriptor, at: 128, count: 2, littleEndian: true)
            let blockSizeBE = integer(descriptor, at: 130, count: 2, littleEndian: false)
            guard blocksLE == blocksBE, blockSizeLE == blockSizeBE else {
                throw InspectionError.malformedISO("volume-size fields disagree between byte orders.")
            }
            guard blocksLE > UInt64(sector), blockSizeLE == 2048 else {
                throw InspectionError.malformedISO("invalid volume size or unsupported logical block size.")
            }
            let declared = blocksLE * UInt64(stride)
            guard declared <= size else {
                throw InspectionError.malformedISO("the declared volume exceeds the available file bytes.")
            }
            if size > declared { notes.append("Bytes follow the declared volume; their purpose is not yet inspected.") }
            let label = String(data: descriptor.subdata(in: 40..<72), encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return DiscInspection(filename: url.lastPathComponent, byteCount: size,
                format: "ISO 9660 descriptor (\(stride)-byte sectors)", volumeLabel: label,
                declaredVolumeBytes: declared, notes: notes,
                gameID: try gameID(handle, descriptor: descriptor, size: size, stride: stride, userOffset: userOffset))
        }
        return DiscInspection(filename: url.lastPathComponent, byteCount: size,
            format: "Unrecognized by this inspector", volumeLabel: nil, declaredVolumeBytes: nil,
            notes: notes + ["Raw BIN sectors, encrypted images and other layouts are not supported yet. A filename extension is not proof of format."])
    }

    // Read only the root directory and SYSTEM.CNF, with strict allocation/range limits.
    private static func gameID(_ handle: FileHandle, descriptor: Data, size: UInt64, stride: Int, userOffset: Int) throws -> String? {
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            var result = Data(), position = offset
            while result.count < count {
                let physical = position / 2048 * UInt64(stride) + UInt64(userOffset) + position % 2048
                let n = min(count-result.count,2048-Int(position%2048))
                guard physical <= size, UInt64(n) <= size-physical else { return Data() }
                try handle.seek(toOffset:physical)
                let data = try handle.read(upToCount:n) ?? Data()
                guard data.count==n else { return Data() }; result.append(data); position += UInt64(n)
            }
            return result
        }
        let extent = integer(descriptor, at: 158, count: 4, littleEndian: true) * 2048
        let count = integer(descriptor, at: 166, count: 4, littleEndian: true)
        guard count > 0, count <= 4 * 1024 * 1024, extent <= size, count <= size - extent else { return nil }
        let root = try read(extent,Int(count))
        var position = 0
        while position < root.count {
            let length = Int(root[position])
            if length == 0 { position = (position / 2048 + 1) * 2048; continue }
            guard length >= 34, position + length <= root.count else { return nil }
            let record = Data(root[position..<(position + length)])
            let nameLength = Int(record[32])
            guard 33 + nameLength <= length else { return nil }
            let name = String(decoding: record[33..<(33 + nameLength)], as: UTF8.self).uppercased()
            if name == "SYSTEM.CNF;1" || name == "SYSTEM.CNF" {
                let offset = integer(record, at: 2, count: 4, littleEndian: true) * 2048
                let bytes = integer(record, at: 10, count: 4, littleEndian: true)
                guard bytes > 0, bytes <= 65536, offset <= size, bytes <= size - offset else { return nil }
                let text = String(decoding: try read(offset,Int(bytes)), as: UTF8.self).uppercased()
                let regex = try NSRegularExpression(pattern: #"BOOT2\s*=.*?([A-Z]{4})[_-]([0-9]{3})\.([0-9]{2})"#)
                guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
                return (1...3).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }.joined()
            }
            position += length
        }
        return nil
    }

    private static func integer(_ data: Data, at offset: Int, count: Int, littleEndian: Bool) -> UInt64 {
        let bytes = Array(data[offset..<(offset + count)])
        return (littleEndian ? Array(bytes.reversed()) : bytes).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
