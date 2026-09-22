// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class AT3ConverterTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @discardableResult
    private func writeWAV(_ url: URL, channels: Int = 2, rate: Int = 44100, bits: Int = 16,
                          seconds: Double = 0.5, format: Int = 1) throws -> URL {
        let frames = Int(Double(rate) * seconds)
        let blockAlign = channels * bits / 8
        let dataBytes = frames * blockAlign
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func le(_ value: Int, _ count: Int) { for i in 0..<count { data.append(UInt8((value >> (8 * i)) & 0xff)) } }
        ascii("RIFF"); le(36 + dataBytes, 4); ascii("WAVE")
        ascii("fmt "); le(16, 4); le(format, 2); le(channels, 2); le(rate, 4); le(rate * blockAlign, 4); le(blockAlign, 2); le(bits, 2)
        ascii("data"); le(dataBytes, 4)
        for i in 0..<frames {
            let sample = Int16(12000 * sin(2 * Double.pi * 1000 * Double(i) / Double(rate)))
            for _ in 0..<channels { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        }
        try data.write(to: url)
        return url
    }

    func testInspectAcceptsSupportedAndRejectsOthers() throws {
        try temporary { folder in
            let ok = try writeWAV(folder.appendingPathComponent("ok.wav"))
            let info = try AT3Converter.inspect(ok)
            XCTAssertEqual(info.channels, 2)
            XCTAssertEqual(info.sampleRate, 44100)
            XCTAssertEqual(info.bitsPerSample, 16)
            XCTAssertGreaterThan(info.frames, 0)
            XCTAssertNoThrow(try AT3Converter.inspect(try writeWAV(folder.appendingPathComponent("mono.wav"), channels: 1)))

            func rejects(_ name: String, _ url: URL, _ part: String) {
                XCTAssertThrowsError(try AT3Converter.inspect(url)) { error in
                    XCTAssertTrue(error.localizedDescription.contains(part), "\(name): \(error.localizedDescription)")
                }
            }
            rejects("48k", try writeWAV(folder.appendingPathComponent("48.wav"), rate: 48000), "44,100")
            rejects("8bit", try writeWAV(folder.appendingPathComponent("8.wav"), bits: 8), "16-bit")
            rejects("3ch", try writeWAV(folder.appendingPathComponent("3.wav"), channels: 3), "mono or stereo")
            rejects("compressed", try writeWAV(folder.appendingPathComponent("cmp.wav"), format: 2), "compressed")
            try Data("not a wav".utf8).write(to: folder.appendingPathComponent("bad.wav"))
            rejects("notwav", folder.appendingPathComponent("bad.wav"), "RIFF/WAVE")
        }
    }

    func testConvertRefusesExistingDestination() throws {
        try temporary { folder in
            let wav = try writeWAV(folder.appendingPathComponent("tone.wav"))
            let existing = folder.appendingPathComponent("tone.at3")
            try Data([0]).write(to: existing)
            let runner = ConversionRunner()
            XCTAssertThrowsError(try AT3Converter.convert(source: wav, destination: existing,
                                                          helper: URL(fileURLWithPath: "/nonexistent"),
                                                          runner: runner)) { error in
                XCTAssertTrue(error.localizedDescription.contains("already exists"), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: existing), Data([0]), "an existing destination must be untouched")
        }
    }

    func testInspectRejectsTruncatedPayloadAndInvalidAlignment() throws {
        try temporary { folder in
            let wav = try writeWAV(folder.appendingPathComponent("truncated.wav"))
            var data = try Data(contentsOf: wav)
            try data.prefix(44).write(to: wav)
            XCTAssertThrowsError(try AT3Converter.inspect(wav), "declared samples must actually exist")
            data[32] = 1; data[33] = 0
            try data.write(to: wav)
            XCTAssertThrowsError(try AT3Converter.inspect(wav), "PCM frame alignment must match the channels and sample size")
        }
    }

    func testCancellationAtValidationDoesNotPublish() throws {
        guard let helper = ProcessInfo.processInfo.environment["PS2_TEST_AT3_HELPER"] else {
            throw XCTSkip("set PS2_TEST_AT3_HELPER")
        }
        try temporary { folder in
            let wav = try writeWAV(folder.appendingPathComponent("tone.wav"))
            let out = folder.appendingPathComponent("cancelled.at3")
            let runner = ConversionRunner()
            XCTAssertThrowsError(try AT3Converter.convert(source: wav, destination: out,
                helper: URL(fileURLWithPath: helper), runner: runner) { progress in
                    if progress.stage == "Validating audio" { runner.cancel() }
                }) { error in XCTAssertTrue(error.localizedDescription.contains("Cancelled")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["tone.wav"])
        }
    }

    func testInspectSkipsLargeMetadataWithoutReadingPayload() throws {
        try temporary { folder in
            let wav = try writeWAV(folder.appendingPathComponent("metadata.wav"))
            var data = try Data(contentsOf: wav)
            var junk = Data("JUNK".utf8)
            junk.append(contentsOf: [0, 32, 0, 0])
            junk.append(Data(repeating: 0, count: 8192))
            data.insert(contentsOf: junk, at: 12)
            let size = data.count - 8
            for i in 0..<4 { data[4+i] = UInt8((size >> (8*i)) & 255) }
            try data.write(to: wav)
            XCTAssertEqual(try AT3Converter.inspect(wav).frames, 22050)
        }
    }

    /// Real encode via the bundled helper. Gated on PS2_TEST_AT3_HELPER.
    func testRealEncodeProducesValidAT3() throws {
        guard let helperPath = ProcessInfo.processInfo.environment["PS2_TEST_AT3_HELPER"],
              FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw XCTSkip("set PS2_TEST_AT3_HELPER to run the real ATRAC3 encode")
        }
        try temporary { folder in
            let wav = try writeWAV(folder.appendingPathComponent("tone.wav"), seconds: 0.5)
            let out = folder.appendingPathComponent("tone.at3")
            let runner = ConversionRunner()
            let data = try AT3Converter.convert(source: wav, destination: out,
                                                helper: URL(fileURLWithPath: helperPath), runner: runner)
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
            XCTAssertNoThrow(try PackageMetadata.validateSound(data), "encoder output must satisfy the app's ATRAC3 rules")
            XCTAssertLessThanOrEqual(data.count, AT3Converter.maxOutputBytes)
            XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
            XCTAssertEqual(Int(data[20]) | (Int(data[21]) << 8), 0x270, "fmt tag must be ATRAC3 (0x270)")
            XCTAssertEqual(try Data(contentsOf: wav).prefix(4), Data("RIFF".utf8), "the source must be unchanged")
            // A private temp file must not be left behind.
            let leftovers = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".ps2-at3-") }
            XCTAssertTrue(leftovers.isEmpty, "the encoder temp file must be cleaned up")
        }
    }
}
