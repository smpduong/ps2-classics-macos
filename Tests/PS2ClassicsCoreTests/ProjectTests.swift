// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class ProjectTests: XCTestCase {
    func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:url) }; try body(url)
    }
    func testCUEAcceptsSingleDataTrackAndRejectsAudioPregapsAndEscapes() throws {
        try temporary { folder in
            let cue = folder.appendingPathComponent("disc.cue")
            let valid = "FILE \"Disc café.bin\" BINARY\n TRACK 01 MODE2/2352\n INDEX 01 00:00:00\n"
            try Data(valid.utf8).write(to:cue)
            XCTAssertEqual(try DiscInput.resolve(cue).lastPathComponent,"Disc café.bin")
            for text in [valid+"TRACK 02 AUDIO\n",valid.replacingOccurrences(of:"00:00:00",with:"00:02:00"),valid.replacingOccurrences(of:"Disc café.bin",with:"../escape.bin"),valid+"PREGAP 00:02:00\n"] {
                try Data(text.utf8).write(to:cue); XCTAssertThrowsError(try DiscInput.resolve(cue))
            }
        }
    }
    func testCUEUnsupportedLayoutsHaveSpecificReasons() throws {
        try temporary { folder in
            func message(_ body: String) throws -> String {
                let url = folder.appendingPathComponent("cue-\(UUID().uuidString).cue")
                try Data(body.utf8).write(to: url)
                do { _ = try DiscInput.resolve(url); return "" } catch { return error.localizedDescription }
            }
            let base = "FILE \"disc.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n"
            XCTAssertTrue(try message("FILE \"disc.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n").contains("audio track"))
            XCTAssertTrue(try message("FILE \"disc.bin\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\n").contains("MODE1/2048"))
            XCTAssertTrue(try message("FILE \"disc.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\nTRACK 02 MODE1/2352\nINDEX 01 00:05:00\n").contains("more than one data track"))
            XCTAssertTrue(try message("FILE \"disc.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 00 00:00:00\nINDEX 01 00:02:00\n").contains("pregap"))
            XCTAssertTrue(try message("FILE \"disc.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:02:00\n").contains("starts at 00:02:00"))
            XCTAssertTrue(try message("FILE \"disc.bin\" WAVE\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n").contains("BINARY"))
            XCTAssertTrue(try message("FILE \"a.bin\" BINARY\nFILE \"b.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n").contains("more than one file"))
            XCTAssertTrue(try message("FILE \"disc.bin\" BINARY\nTRACK 01 MODE1/2352\nPREGAP 00:02:00\nINDEX 01 00:00:00\n").contains("PREGAP"))
            // Informational metadata is ignored, not rejected.
            let valid = folder.appendingPathComponent("valid.cue")
            try Data(("TITLE \"My Game\"\nPERFORMER \"Someone\"\n" + base).utf8).write(to: valid)
            XCTAssertEqual(try DiscInput.resolve(valid).lastPathComponent, "disc.bin")
        }
    }

    func testSFOHasCorrectUTF8LengthAndAlignedDataTable() throws {
        let sfo = try PackageMetadata.sfo(title:"テスト café",titleID:"SLUS12345")
        func le(_ offset:Int,_ count:Int)->Int { (0..<count).reduce(0) { $0 | Int(sfo[offset+$1]) << ($1*8) } }
        XCTAssertEqual(sfo.prefix(4),Data([0,80,83,70]))
        let keyStart=le(8,4),dataStart=le(12,4)
        XCTAssertEqual(dataStart%4,0)
        var found=false
        for i in 0..<le(16,4) {
            let offset=20+i*16, keyOffset=keyStart+le(offset,2)
            let key=String(decoding:sfo[keyOffset...].prefix(while:{$0 != 0}),as:UTF8.self)
            if key=="TITLE" {
                let length=le(offset+4,4), value=dataStart+le(offset+12,4)
                XCTAssertEqual(length,"テスト café".utf8.count+1)
                XCTAssertEqual(String(decoding:sfo[value..<(value+length-1)],as:UTF8.self),"テスト café"); found=true
            }
        }
        XCTAssertTrue(found)
        XCTAssertThrowsError(try PackageMetadata.sfo(title:String(repeating:"é",count:64),titleID:"SLUS12345"))
    }
    func testMultiDiscTrailerReplacedWithoutChangingConfigBody() throws {
        let original=Data([0x12,0x34,0x56,0x78])
        let first=try XCTUnwrap(PackageMetadata.config(original,gameID:"SLUS20892",count:2,discIndex:0))
        let second=try XCTUnwrap(PackageMetadata.config(first,gameID:"SLUS21133",count:2,discIndex:1))
        XCTAssertEqual(second.count,21); XCTAssertEqual(second.prefix(4),original)
        XCTAssertEqual(String(decoding:second[8..<18],as:UTF8.self),"SLUS-21133")
        XCTAssertEqual(second.suffix(3),Data([0,2,1]))
        XCTAssertNil(try PackageMetadata.config(nil,gameID:"SLUS12345",count:1,discIndex:0))
    }
    func testAudioRejectsRenamedPCMAndTruncatedChunks() throws {
        var bytes=Data("RIFF".utf8)+Data([38,0,0,0])+Data("WAVEfmt ".utf8)+Data([16,0,0,0])
        bytes.append(Data([0x70,0x02,2,0,0x44,0xAC,0,0,0,0,0,0,0,0,0,0]))
        bytes.append(Data("data".utf8));bytes.append(Data([2,0,0,0,1,2]))
        XCTAssertNoThrow(try PackageMetadata.validateSound(bytes))
        bytes[20]=1;bytes[21]=0;XCTAssertThrowsError(try PackageMetadata.validateSound(bytes))
        bytes[20]=0x70;bytes[21]=2;bytes.removeLast();XCTAssertThrowsError(try PackageMetadata.validateSound(bytes))
    }
    func testProjectRoundTripAndExistingOutputRejection() throws {
        try temporary { folder in
            var project=GameProject(); project.title="Example";project.titleID="SLUS12345"
            project.discs=[GameDisc(source:folder.appendingPathComponent("test.iso"),gameID:"SLUS12345")]
            project.support.key=folder.appendingPathComponent("key");project.support.rap=folder.appendingPathComponent("rap")
            project.support.card=folder.appendingPathComponent("card");project.support.logo=folder.appendingPathComponent("logo")
            project.support.contentID="UP0001-SLUS12345_00-0000000000000001";project.output=folder.appendingPathComponent("output.pkg")
            try project.validate()
            let recovered=try JSONDecoder().decode(GameProject.self,from:JSONEncoder().encode(project))
            XCTAssertEqual(recovered.discs[0].source,project.discs[0].source)
            try Data([1]).write(to:project.output!);XCTAssertThrowsError(try project.validate())
        }
    }
    func testBootIDAcrossSectorLayoutsAndMalformedRootIsBounded() throws {
        try temporary { folder in
            var iso=Data(count:24*2048);let p=16*2048
            iso[p]=1;iso.replaceSubrange(p+1..<p+6,with:Data("CD001".utf8));iso[p+6]=1
            iso[p+80]=24;iso[p+87]=24;iso[p+129]=8;iso[p+130]=8
            iso[p+156]=34;iso[p+158]=20;iso[p+167]=8
            let r=20*2048;let name=Data("SYSTEM.CNF;1".utf8)
            let cnf=Data("BOOT2 = cdrom0:\\SLUS_208.92;1\r\n".utf8)
            iso[r]=46;iso[r+2]=21;iso[r+10]=UInt8(cnf.count);iso[r+32]=UInt8(name.count)
            iso.replaceSubrange(r+33..<r+33+name.count,with:name);iso.replaceSubrange(21*2048..<21*2048+cnf.count,with:cnf)
            let url=folder.appendingPathComponent("disc.iso")
            try iso.write(to:url);XCTAssertEqual(try DiscInspector.inspect(url).gameID,"SLUS20892")
            for offset in [16,24] {
                var raw=Data(count:24*2352)
                for sector in 0..<24 { raw.replaceSubrange(sector*2352+offset..<sector*2352+offset+2048,with:iso[sector*2048..<(sector+1)*2048]) }
                try raw.write(to:url);let result=try DiscInspector.inspect(url)
                XCTAssertEqual(result.gameID,"SLUS20892");XCTAssertTrue(result.format.contains("2352"))
            }
            iso[p+169]=255;try iso.write(to:url);XCTAssertNil(try DiscInspector.inspect(url).gameID)
        }
    }
}
