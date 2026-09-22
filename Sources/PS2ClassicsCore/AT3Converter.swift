// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Converts supported local audio to ATRAC3 using system audio normalization
/// and the bundled encoder. Structured helper arguments and a private workspace
/// keep original audio read-only. The result is checked
/// against the app's own ATRAC3 rules before an exclusive publication. A source
/// file is never overwritten and no existing destination is replaced.
public enum AT3Converter {
    /// SND0.AT3 support data must stay within the helper's accepted size.
    public static let maxOutputBytes = 2_500_000
    public static let supportedSampleRate = 44_100
    public static let supportedBitsPerSample = 16

    public struct InputInfo: Sendable, Equatable {
        public let channels: Int
        public let sampleRate: Int
        public let bitsPerSample: Int
        public let frames: Int
        public init(channels: Int, sampleRate: Int, bitsPerSample: Int, frames: Int) {
            self.channels = channels; self.sampleRate = sampleRate
            self.bitsPerSample = bitsPerSample; self.frames = frames
        }
    }

    private static func header(_ url: URL, bytes: Int) throws -> Data {
        guard url.isFileURL else { throw ConversionFailure(message: "Choose a local WAV file.") }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConversionFailure(message: "Choose a regular WAV file, not a folder or symbolic link.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: bytes) ?? Data()
    }

    /// Reads only the RIFF header and validates the supported PCM layout.
    public static func inspect(_ url: URL, allowNormalization: Bool = false) throws -> InputInfo {
        let initial = try header(url, bytes: 12)
        guard initial.count == 12, initial.prefix(4) == Data("RIFF".utf8), initial.suffix(4) == Data("WAVE".utf8) else {
            throw ConversionFailure(message: "That file is not a RIFF/WAVE audio file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileBytes = try handle.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ConversionFailure(message: "The WAV file is truncated.") }
            return data
        }
        func uint(_ data: Data, _ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        let header = try read(0, 12)
        guard header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else {
            throw ConversionFailure(message: "That file is not a RIFF/WAVE audio file. Choose a 44.1 kHz 16-bit WAV.")
        }
        let riffEnd = UInt64(uint(header, 4, 4)) + 8
        guard riffEnd >= 12, riffEnd <= fileBytes else { throw ConversionFailure(message: "The WAV file is truncated.") }
        var offset: UInt64 = 12
        var format: Int?, channels: Int?, rate: Int?, bits: Int?, blockAlign: Int?, byteRate: Int?
        var payloadBytes: Int?
        var chunks = 0
        while offset < riffEnd {
            chunks += 1
            guard chunks <= 4096, riffEnd - offset >= 8 else {
                throw ConversionFailure(message: "The WAV chunk layout is incomplete or unsupported.")
            }
            let chunk = try read(offset, 8)
            let size = uint(chunk, 4, 4), start = offset + 8
            let end = start + UInt64(size)
            guard end <= riffEnd, end + UInt64(size % 2) <= riffEnd else {
                throw ConversionFailure(message: "The WAV payload is truncated.")
            }
            if chunk.prefix(4) == Data("fmt ".utf8) {
                guard format == nil, size >= 16 else { throw ConversionFailure(message: "The WAV format chunk is invalid.") }
                let fmt = try read(start, 16)
                format = uint(fmt, 0, 2); channels = uint(fmt, 2, 2)
                rate = uint(fmt, 4, 4); byteRate = uint(fmt, 8, 4)
                blockAlign = uint(fmt, 12, 2); bits = uint(fmt, 14, 2)
                if format == 0xfffe, allowNormalization {
                    guard size >= 40 else { throw ConversionFailure(message: "The extended WAV format is incomplete.") }
                    let extended = try read(start, 40)
                    let guidTail = Data([0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71])
                    let validBits = uint(extended, 18, 2)
                    guard uint(extended, 16, 2) >= 22,
                          uint(extended, 16, 2) + 18 <= size,
                          extended.subdata(in: 28..<40) == guidTail,
                          validBits > 0, validBits <= uint(extended, 14, 2) else {
                        throw ConversionFailure(message: "The extended WAV sample format is unsupported.")
                    }
                    format = uint(extended, 24, 4)
                }
            } else if chunk.prefix(4) == Data("data".utf8) {
                guard payloadBytes == nil else { throw ConversionFailure(message: "Multiple WAV audio payloads are unsupported.") }
                payloadBytes = size
            }
            offset = end + UInt64(size % 2)
        }
        guard let format = format, let channels = channels, let rate = rate, let bits = bits else {
            throw ConversionFailure(message: "The WAV header is incomplete or unsupported.")
        }
        guard format == 1 || (allowNormalization && format == 3) else { throw ConversionFailure(message: "Only uncompressed PCM WAV input is supported (that file uses a compressed format).") }
        guard allowNormalization ? ((format == 1 && [8, 16, 24, 32].contains(bits)) || (format == 3 && [32, 64].contains(bits))) : bits == supportedBitsPerSample else { throw ConversionFailure(message: allowNormalization ? "Unsupported \(bits)-bit WAV audio. Use 8/16/24/32-bit PCM or 32/64-bit floating point." : "Only 16-bit WAV input is supported (that file is \(bits)-bit).") }
        guard allowNormalization ? (8_000...192_000).contains(rate) : rate == supportedSampleRate else { throw ConversionFailure(message: allowNormalization ? "Audio sample rates must be between 8,000 and 192,000 Hz (that file is \(rate) Hz)." : "Only 44,100 Hz WAV input is supported (that file is \(rate) Hz).") }
        guard (1...2).contains(channels) else { throw ConversionFailure(message: "Only mono or stereo WAV input is supported (that file has \(channels) channels).") }
        guard let align = blockAlign, align == channels * (bits / 8),
              byteRate == rate * align, let payload = payloadBytes, payload % align == 0 else {
            throw ConversionFailure(message: "The WAV sample alignment or audio payload is invalid.")
        }
        let frames = payload / align
        guard frames > 0 else { throw ConversionFailure(message: "The WAV file contains no audio samples.") }
        return InputInfo(channels: channels, sampleRate: rate, bitsPerSample: bits, frames: frames)
    }

    /// Encodes `source` to an ATRAC3 RIFF file at `destination`. The encoder
    /// writes to a private temporary file first; the result must satisfy the
    /// app's ATRAC3 rules and the size limit before it is published exclusively.
    /// A `ConversionRunner` is accepted so the caller can cancel the encoder.
    @discardableResult
    public static func convert(source: URL, destination: URL, helper: URL,
                               runner: ConversionRunner,
                               progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) throws -> Data {
        _ = try AudioNormalizer.inspect(source)
        try runner.checkCancellation()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw ConversionFailure(message: "The destination already exists. Choose a new filename; existing files are never replaced.")
        }
        let parent = destination.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw ConversionFailure(message: "The destination folder is not writable: \(parent.lastPathComponent).")
        }
        try DestinationCheck.probeWritable(folder: parent)
        let workspace = parent.appendingPathComponent(".ps2-at3-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let temp = workspace.appendingPathComponent("encoded.at3")
        defer { try? fm.removeItem(at: workspace) }
        let normalized = workspace.appendingPathComponent("normalized.wav")
        try AudioNormalizer.normalize(source: source, destination: normalized, runner: runner, progress: progress)
        try runner.checkCancellation()
        progress(ConversionProgress(stage: "Encoding audio", fraction: 0.3))
        do {
            try runner.run(arguments: ["-e", "atrac3", "--container", "riff", "-i", normalized.path, "-o", temp.path],
                           helper: helper, progress: progress, requiresCompletion: false)
        } catch {
            try runner.checkCancellation()
            throw error
        }
        try runner.checkCancellation()
        guard fm.fileExists(atPath: temp.path) else {
            throw ConversionFailure(message: "The encoder produced no output.")
        }
        let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw ConversionFailure(message: "The encoder produced an empty file.") }
        guard size <= maxOutputBytes else {
            throw ConversionFailure(message: "The encoded audio is larger than the 2.5 MB limit support data allows. Use a shorter clip.")
        }
        let data = try BoundedFile.read(temp, maximum: maxOutputBytes)
        try PackageMetadata.validateSound(data)
        progress(ConversionProgress(stage: "Validating audio", fraction: 0.95))
        try runner.checkCancellation()
        if renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let renameError = errno
            guard [ENOTSUP, EOPNOTSUPP, EINVAL].contains(renameError),
                  link(temp.path, destination.path) == 0 else {
                throw ConversionFailure(message: "Cannot publish audio exclusively. Choose a new filename on an APFS or Mac OS Extended volume.")
            }
        }
        progress(ConversionProgress(stage: "Encoded audio", fraction: 1))
        return data
    }
}
