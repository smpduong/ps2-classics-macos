// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class NetworkWorkflowTests:XCTestCase {
    func temporary(_ body:(URL)throws->Void)throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)};try body(root)
    }
    func testSettingsRejectCommandInjectionAndCatalogRejectsBadIdentity() throws {
        for host in ["ftp://localhost","localhost/path","localhost\nquote=DELE /","user@host"] {
            XCTAssertThrowsError(try FTPDestination(host:host,directory:"/packages"))
        }
        for directory in ["relative","/a/../b","/a\r\nDELE /b"] {
            XCTAssertThrowsError(try FTPDestination(host:"localhost",directory:directory))
        }
        XCTAssertThrowsError(try FTPDestination(host:"localhost",directory:"/",username:"a:b"))
        XCTAssertThrowsError(try FTPDestination(host:"localhost",directory:"/",password:"a\nb"))
        let setting=try FTPDestination(host:"127.0.0.1",directory:"/packages with spaces")
        XCTAssertEqual(try setting.url("/packages with spaces/x"),"ftp://127.0.0.1:21//packages%20with%20spaces/x")
        for url in ["http://example.com/a","https://user:secret@example.com/a","https://example.com/a#b","file:///tmp/a"] {
            XCTAssertThrowsError(try OnlineConfigCatalog.validateURL(URL(string:url)!))
        }
        let data=Data([1,2,3,4]),hash=FileDigest.sha256(data:data)
        let json: [String:Any] = ["version":1,"source":"Synthetic publisher","revision":"r1","license":"Synthetic test only","entries":[["gameID":"SLUS12345","title":"Test","url":"https://example.invalid/config","sha256":hash,"bytes":4]]]
        let catalog=try OnlineConfigCatalog.decode(JSONSerialization.data(withJSONObject:json))
        try temporary {root in
            let url=try catalog.store(data,entry:catalog.entries[0],into:root,runner:ConversionRunner())
            XCTAssertEqual(try Data(contentsOf:url),data)
            XCTAssertTrue(FileManager.default.fileExists(atPath:url.deletingLastPathComponent().appendingPathComponent("catalog.json").path))
            XCTAssertThrowsError(try catalog.store(Data([4,3,2,1]),entry:catalog.entries[0],into:root,runner:ConversionRunner()))
            let cancelled=ConversionRunner();cancelled.cancel()
            XCTAssertThrowsError(try catalog.store(data,entry:catalog.entries[0],into:root,runner:cancelled))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).count,1)
        }
        var bad=json;bad["version"]=2
        XCTAssertThrowsError(try OnlineConfigCatalog.decode(JSONSerialization.data(withJSONObject:bad)))
        bad=json;bad["entries"]=(json["entries"] as! [[String:Any]])+(json["entries"] as! [[String:Any]])
        XCTAssertThrowsError(try OnlineConfigCatalog.decode(JSONSerialization.data(withJSONObject:bad)))
    }
    func testProcessOutputIsBoundedAndInputIsPrivate() throws {
        let runner=ConversionRunner()
        XCTAssertThrowsError(try runner.capture(arguments:["-c","while :; do printf 0123456789; done"],helper:URL(fileURLWithPath:"/bin/sh"),maximumOutput:128))
        XCTAssertEqual(try runner.capture(arguments:[],helper:URL(fileURLWithPath:"/bin/cat"),input:Data("test-password".utf8)),Data("test-password".utf8))
        let cancelled=ConversionRunner();cancelled.cancel()
        XCTAssertThrowsError(try cancelled.capture(arguments:[],helper:URL(fileURLWithPath:"/bin/cat")))
    }
    func package(_ root:URL,_ helper:URL)throws->URL {
        var data=Data(repeating:0,count:24*2048);let p=16*2048
        data[p]=1;data.replaceSubrange(p+1..<p+6,with:Data("CD001".utf8));data[p+6]=1
        data[p+80]=24;data[p+87]=24;data[p+129]=8;data[p+130]=8
        let iso=root.appendingPathComponent("test.iso");try data.write(to:iso)
        try Data(repeating:1,count:16).write(to:root.appendingPathComponent("klic.bin"))
        try Data(repeating:2,count:16).write(to:root.appendingPathComponent("license.rap"))
        try Data([3]).write(to:root.appendingPathComponent("PS3LOGO.DAT"))
        var card=Data(repeating:0,count:8650752);card.replaceSubrange(0..<28,with:Data("Sony PS2 Memory Card Format ".utf8));try card.write(to:root.appendingPathComponent("SCEVMC0.VMC"))
        var project=GameProject();project.title="Network fixture";project.titleID="SLUS12345"
        project.discs=[GameDisc(source:iso,gameID:"SLUS12345")]
        project.support.key=root.appendingPathComponent("klic.bin");project.support.rap=root.appendingPathComponent("license.rap")
        project.support.logo=root.appendingPathComponent("PS3LOGO.DAT");project.support.card=root.appendingPathComponent("SCEVMC0.VMC")
        project.support.contentID="UP0001-SLUS12345_00-0000000000000001"
        project.output=root.appendingPathComponent("fixture.pkg")
        _ = try PackageBuilder().build(project,helper:helper){_ in};return project.output!
    }
    func testFTPReadbackCorruptionCancellationAndExistingFiles() throws {
        guard let path=ProcessInfo.processInfo.environment["PS2_TEST_HELPER"] else{throw XCTSkip("Set PS2_TEST_HELPER")}
        try temporary {root in
            let helper=URL(fileURLWithPath:path),local=try package(root,helper),before=try FileDigest.sha256(local)
            let remote=root.appendingPathComponent("remote");try FileManager.default.createDirectory(at:remote,withIntermediateDirectories:false)
            let existing=remote.appendingPathComponent("keep.pkg");try Data("preserve".utf8).write(to:existing)
            let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            let script=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/ftp-fixture.py")
            process.arguments=[script.path,remote.path];process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            try process.run();defer{process.terminate();process.waitUntilExit()}
            let response=pipe.fileHandleForReading.availableData
            let port=try XCTUnwrap(Int(String(decoding:response,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)))
            let target=try FTPDestination(host:"127.0.0.1",port:port,directory:"/",username:"fixture",password:"test-only")
            let final=try ConsoleTransfer.send(package:local,destination:target,helper:helper,runner:ConversionRunner())
            XCTAssertEqual(try FileDigest.sha256(remote.appendingPathComponent(String(final.dropFirst()))),before)
            for mode in ["corrupt","truncate","oversize","deny"] {
                try Data(mode.utf8).write(to:remote.appendingPathComponent("mode"))
                XCTAssertThrowsError(try ConsoleTransfer.send(package:local,destination:target,helper:helper,runner:ConversionRunner()),mode)
            }
            try Data().write(to:remote.appendingPathComponent("mode"))
            let cancelled=ConversionRunner()
            XCTAssertThrowsError(try ConsoleTransfer.send(package:local,destination:target,helper:helper,runner:cancelled){update in if update.stage.hasPrefix("Reading back"), update.fraction > 0.5 {cancelled.cancel()}})
            let files=FileManager.default.enumerator(at:remote,includingPropertiesForKeys:nil)!.allObjects as! [URL]
            XCTAssertEqual(files.filter{$0.lastPathComponent=="package.pkg"}.count,1)
            XCTAssertEqual(try String(contentsOf:existing),"preserve")
            XCTAssertEqual(try FileDigest.sha256(local),before)
        }
    }
}
