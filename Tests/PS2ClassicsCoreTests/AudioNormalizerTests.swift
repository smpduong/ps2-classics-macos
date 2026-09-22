// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class AudioNormalizerTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func wav(_ url: URL, rate: Int = 48_000, bits: Int = 24, channels: Int = 2,
                     seconds: Double = 0.1, floating: Bool = false) throws {
        let frames = Int(Double(rate) * seconds), alignment = channels * bits / 8
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func le(_ v: Int, _ n: Int) { for i in 0..<n { data.append(UInt8((v >> (8*i)) & 255)) } }
        ascii("RIFF"); le(36 + frames * alignment + (frames * alignment) % 2, 4); ascii("WAVEfmt "); le(16, 4)
        le(floating ? 3 : 1, 2); le(channels, 2); le(rate, 4); le(rate * alignment, 4)
        le(alignment, 2); le(bits, 2); ascii("data"); le(frames * alignment, 4)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let sample = 0.25 * sin(2 * Double.pi * Double(channel == 0 ? 440 : 1000) * Double(frame) / Double(rate))
                if floating { le(Int(Float(sample).bitPattern), 4) }
                else if bits == 8 { le(Int(sample * 127) + 128, 1) }
                else { le(Int(sample * Double((1 << (bits-1)) - 1)), bits / 8) }
            }
        }
        if (frames * alignment) % 2 != 0 { data.append(0) }
        try data.write(to: url)
    }

    func testResamplesPCMWithoutChangingChannelsOrSource() throws {
        try temporary { folder in
            for (rate, bits, channels, floating) in [(48_000, 24, 2, false), (22_050, 8, 1, false), (96_000, 32, 2, true)] {
                let source = folder.appendingPathComponent("source.wav"), output = folder.appendingPathComponent("normalized.wav")
                try wav(source, rate: rate, bits: bits, channels: channels, floating: floating)
                let original = try Data(contentsOf: source)
                let info = try AudioNormalizer.inspect(source)
                XCTAssertEqual(info.channels, channels)
                XCTAssertEqual(info.sampleRate, Double(rate))
                try AudioNormalizer.normalize(source: source, destination: output, runner: ConversionRunner(), progress: { _ in })
                let normalized = try AT3Converter.inspect(output)
                XCTAssertEqual(normalized.channels, channels)
                XCTAssertEqual(normalized.sampleRate, 44_100)
                XCTAssertEqual(normalized.bitsPerSample, 16)
                XCTAssertEqual(Double(normalized.frames), 4410, accuracy: 2)
                XCTAssertEqual(try Data(contentsOf: source), original)
                try FileManager.default.removeItem(at: output)
            }
        }
    }

    func testRejectsTruncationSurroundAndLongClips() throws {
        try temporary { folder in
            let source = folder.appendingPathComponent("source.wav")
            try wav(source, channels: 3)
            XCTAssertThrowsError(try AudioNormalizer.inspect(source))
            try wav(source, rate: 8_000, bits: 8, channels: 1, seconds: 151)
            XCTAssertThrowsError(try AudioNormalizer.inspect(source)) { error in
                XCTAssertTrue(error.localizedDescription.contains("2 minutes 30"))
            }
            try wav(source)
            let data = try Data(contentsOf: source)
            try data.prefix(48).write(to: source)
            XCTAssertThrowsError(try AudioNormalizer.inspect(source))
        }
    }

    func testRejectsSymbolicLinksAndKeepsExistingDestination() throws {
        try temporary { folder in
            let source = folder.appendingPathComponent("source.wav"), link = folder.appendingPathComponent("link.wav")
            try wav(source)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            XCTAssertThrowsError(try AudioNormalizer.inspect(link))
            let destination = folder.appendingPathComponent("existing.wav"), original = Data("keep me".utf8)
            try original.write(to: destination)
            XCTAssertThrowsError(try AudioNormalizer.normalize(source: source, destination: destination, runner: ConversionRunner(), progress: { _ in }))
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func testCancellationDuringNormalizationCleansWorkspaceWithoutRunningEncoder() throws {
        try temporary { folder in
            let source = folder.appendingPathComponent("source.wav"), output = folder.appendingPathComponent("out.at3")
            try wav(source, seconds: 1)
            let original = try Data(contentsOf: source), runner = ConversionRunner()
            XCTAssertThrowsError(try AT3Converter.convert(source: source, destination: output,
                helper: URL(fileURLWithPath: "/must-not-run"), runner: runner) { update in
                    if update.stage == "Preparing audio" { runner.cancel() }
                }) { error in XCTAssertTrue(error.localizedDescription.contains("Cancelled"), error.localizedDescription) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["source.wav"])
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testMaximumDurationFitsSoundLimit() throws {
        guard let helper = ProcessInfo.processInfo.environment["PS2_TEST_AT3_HELPER"] else { throw XCTSkip("set PS2_TEST_AT3_HELPER") }
        try temporary { folder in
            let source = folder.appendingPathComponent("maximum.wav"), output = folder.appendingPathComponent("maximum.at3")
            try wav(source, rate: 8_000, bits: 8, channels: 1, seconds: AudioNormalizer.maximumDuration)
            let result = try AT3Converter.convert(source: source, destination: output,
                helper: URL(fileURLWithPath: helper), runner: ConversionRunner())
            XCTAssertLessThanOrEqual(result.count, AT3Converter.maxOutputBytes)
            try PackageMetadata.validateSound(result)
        }
    }

    /// Generated compressed fixtures come from an independent FFmpeg installation.
    /// The external script also decodes the final AT3 and checks channel content.
    func testIndependentFormatFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["PS2_TEST_AUDIO_FIXTURES"],
              let helper = ProcessInfo.processInfo.environment["PS2_TEST_AT3_HELPER"] else {
            throw XCTSkip("run scripts/test-audio-formats.py with an independent FFmpeg")
        }
        let folder = URL(fileURLWithPath: path)
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: folder.appendingPathComponent("inputs.json")))
        XCTAssertGreaterThanOrEqual(names.count, 7)
        for name in names {
            let source = folder.appendingPathComponent(name), original = try FileDigest.sha256(source)
            let info = try AudioNormalizer.inspect(source)
            XCTAssertEqual(info.channels, 2, name)
            try AudioNormalizer.normalize(source: source, destination: folder.appendingPathComponent(name + ".normalized.wav"),
                runner: ConversionRunner(), progress: { _ in })
            let output = folder.appendingPathComponent(name + ".at3")
            let audio = try AT3Converter.convert(source: source, destination: output,
                helper: URL(fileURLWithPath: helper), runner: ConversionRunner())
            try PackageMetadata.validateSound(audio)
            XCTAssertEqual(try FileDigest.sha256(source), original, name)
        }
    }
}
