// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AudioToolbox
import Darwin

/// System audio decoding into the encoder's PCM format. Reads and writes small
/// blocks; neither the compressed input nor the decoded clip is held in memory.
public enum AudioNormalizer {
    public static let maximumDuration: Double = 150
    public struct InputInfo: Sendable, Equatable {
        public let channels: Int
        public let sampleRate: Double
        public let duration: Double
    }

    private static func checked(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            throw ConversionFailure(message: "Cannot \(action). The audio may be damaged, protected, or unsupported by macOS (error \(status)).")
        }
    }

    private static func open(_ url: URL) throws -> ExtAudioFileRef {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, bytes <= 512 * 1024 * 1024 else {
            throw ConversionFailure(message: "Choose a regular local audio file up to 512 MB, not a folder or symbolic link.")
        }
        // Core Audio can tolerate truncated WAVs. Keep our stricter RIFF extent
        // and PCM alignment checks instead of silently encoding a damaged clip.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        if header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) {
            _ = try AT3Converter.inspect(url, allowNormalization: true)
        }
        var file: ExtAudioFileRef?
        try checked(ExtAudioFileOpenURL(url as CFURL, &file), "open this audio file")
        guard let file else { throw ConversionFailure(message: "The audio file could not be opened.") }
        return file
    }

    private static func inspect(_ file: ExtAudioFileRef) throws -> InputInfo {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checked(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format), "read the audio format")
        guard [kAudioFormatLinearPCM, kAudioFormatMPEGLayer3, kAudioFormatMPEG4AAC,
               kAudioFormatAppleLossless, kAudioFormatFLAC].contains(format.mFormatID) else {
            throw ConversionFailure(message: "Choose PCM WAV, AIFF, MP3, AAC/ALAC M4A, or FLAC audio.")
        }
        guard (1...2).contains(format.mChannelsPerFrame) else {
            throw ConversionFailure(message: "Choose mono or stereo audio. Surround channels are not mixed down automatically.")
        }
        guard format.mSampleRate.isFinite, (8_000...192_000).contains(format.mSampleRate) else {
            throw ConversionFailure(message: "Audio sample rates must be between 8,000 and 192,000 Hz.")
        }
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        try checked(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames), "read the audio duration")
        let duration = Double(frames) / format.mSampleRate
        guard frames > 0 else { throw ConversionFailure(message: "The audio file contains no samples.") }
        guard duration <= maximumDuration else {
            throw ConversionFailure(message: "Choose an audio clip no longer than 2 minutes 30 seconds to stay within the package sound limit.")
        }
        return InputInfo(channels: Int(format.mChannelsPerFrame), sampleRate: format.mSampleRate, duration: duration)
    }

    public static func inspect(_ source: URL) throws -> InputInfo {
        let file = try open(source)
        defer { ExtAudioFileDispose(file) }
        return try inspect(file)
    }

    /// Destination must be a fresh file inside the caller's private workspace.
    /// Any failure removes only the file created by this call.
    static func normalize(source: URL, destination: URL, runner: ConversionRunner,
                          progress: @escaping @Sendable (ConversionProgress) -> Void) throws {
        try runner.checkCancellation()
        let file = try open(source)
        defer { ExtAudioFileDispose(file) }
        let info = try inspect(file)
        let channels = UInt32(info.channels), alignment = channels * 2
        var format = AudioStreamBasicDescription(mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: alignment, mFramesPerPacket: 1, mBytesPerFrame: alignment,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        try checked(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format), "prepare this audio for conversion")
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ConversionFailure(message: "Cannot create the temporary audio file without replacing an existing file.") }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        try output.write(contentsOf: Data(repeating: 0, count: 44))
        var samples = [Int16](repeating: 0, count: 4096 * info.channels)
        var totalFrames = 0
        while true {
            try runner.checkCancellation()
            var frames: UInt32 = 4096
            try samples.withUnsafeMutableBytes { bytes in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: channels, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                try checked(ExtAudioFileRead(file, &frames, &buffers), "decode this audio")
                guard frames <= 4096 else { throw ConversionFailure(message: "The audio decoder returned too many samples.") }
                guard totalFrames + Int(frames) <= Int(maximumDuration * 44_100) else {
                    throw ConversionFailure(message: "The decoded audio exceeds 2 minutes 30 seconds. Choose a shorter clip.")
                }
                if frames > 0 { try output.write(contentsOf: Data(bytes: bytes.baseAddress!, count: Int(frames * alignment))) }
            }
            if frames == 0 { break }
            totalFrames += Int(frames)
            progress(ConversionProgress(stage: "Preparing audio", fraction: min(0.3, Double(totalFrames) / (info.duration * 44_100) * 0.3)))
        }
        try runner.checkCancellation()
        guard totalFrames > 0 else { throw ConversionFailure(message: "The audio decoder produced no samples.") }
        var header = Data()
        func ascii(_ value: String) { header.append(contentsOf: value.utf8) }
        func le(_ value: Int, _ count: Int) { for i in 0..<count { header.append(UInt8((value >> (8 * i)) & 255)) } }
        let bytes = totalFrames * Int(alignment)
        ascii("RIFF"); le(36 + bytes, 4); ascii("WAVEfmt "); le(16, 4)
        le(1, 2); le(info.channels, 2); le(44_100, 4); le(44_100 * Int(alignment), 4)
        le(Int(alignment), 2); le(16, 2); ascii("data"); le(bytes, 4)
        try output.seek(toOffset: 0)
        try output.write(contentsOf: header)
        try output.close()
        _ = try AT3Converter.inspect(destination)
        complete = true
    }
}
