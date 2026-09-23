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
        // Port bounds and overlong settings are rejected before any network use.
        for port in [0, 65536, -1] {
            XCTAssertThrowsError(try FTPDestination(host:"localhost",port:port,directory:"/packages"))
        }
        XCTAssertThrowsError(try FTPDestination(host:String(repeating:"a",count:300),directory:"/packages"))
        XCTAssertThrowsError(try FTPDestination(host:"localhost",directory:"/"+String(repeating:"a",count:2000)))
        XCTAssertThrowsError(try FTPDestination(host:"localhost",directory:"/packages",username:String(repeating:"u",count:129)))
        XCTAssertThrowsError(try FTPDestination(host:"localhost",directory:"/packages",password:String(repeating:"p",count:257)))
        let setting=try FTPDestination(host:"127.0.0.1",directory:"/packages with spaces")
        XCTAssertEqual(try setting.url("/packages with spaces/x"),"ftp://127.0.0.1:21//packages%20with%20spaces/x")
        for url in ["http://example.com/a","https://user:secret@example.com/a","https://example.com/a#b","file:///tmp/a"] {
            XCTAssertThrowsError(try OnlineConfigCatalog.validateURL(URL(string:url)!))
        }
        XCTAssertThrowsError(try OnlineConfigCatalog.validateURL(URL(string:"https://example.invalid/"+String(repeating:"a",count:2048))!))
        // Schema negatives: uppercase digest, zero bytes, empty list, long title.
        let data=Data([1,2,3,4]),hash=FileDigest.sha256(data:data)
        func catalogJSON(_ entry: [String:Any], entries: Any? = nil) -> Data {
            let json: [String:Any] = ["version":1,"source":"Synthetic publisher","revision":"r1","license":"Synthetic test only","entries":entries ?? [entry]]
            return try! JSONSerialization.data(withJSONObject:json)
        }
        let good:[String:Any]=["gameID":"SLUS12345","title":"Test","url":"https://example.invalid/config","sha256":hash,"bytes":4]
        var upper=good;upper["sha256"]=hash.uppercased()
        XCTAssertThrowsError(try OnlineConfigCatalog.decode(catalogJSON(upper)))
        var zero=good;zero["bytes"]=0
        XCTAssertThrowsError(try OnlineConfigCatalog.decode(catalogJSON(zero)))
        var big=good;big["bytes"]=2*1024*1024
        XCTAssertThrowsError(try OnlineConfigCatalog.decode(catalogJSON(big)))
        var long=good;long["title"]=String(repeating:"t",count:257)
        XCTAssertThrowsError(try OnlineConfigCatalog.decode(catalogJSON(long)))
        let empty: [String:Any] = ["version":1,"source":"Synthetic publisher","revision":"r1","license":"Synthetic test only","entries":[]]
        XCTAssertThrowsError(try OnlineConfigCatalog.decode(try JSONSerialization.data(withJSONObject:empty)))
        let json: [String:Any] = ["version":1,"source":"Synthetic publisher","revision":"r1","license":"Synthetic test only","entries":[["gameID":"SLUS12345","title":"Test","url":"https://example.invalid/config","sha256":hash,"bytes":4]]]
        let catalog=try OnlineConfigCatalog.decode(JSONSerialization.data(withJSONObject:json))
        try temporary {root in
            let url=try catalog.store(data,entry:catalog.entries[0],into:root,runner:ConversionRunner())
            XCTAssertEqual(try Data(contentsOf:url),data)
            XCTAssertTrue(FileManager.default.fileExists(atPath:url.deletingLastPathComponent().appendingPathComponent("catalog.json").path))
            let download=try JSONSerialization.jsonObject(with:Data(contentsOf:url.deletingLastPathComponent().appendingPathComponent("download.json"))) as! [String:Any]
            XCTAssertEqual(download["catalogSource"] as? String,"Synthetic publisher")
            XCTAssertEqual(download["catalogRevision"] as? String,"r1")
            XCTAssertEqual(download["sha256"] as? String,hash)
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
            // Every failure names the outcome: a created folder is left for
            // inspection and identified; a denied directory starts nothing.
            for mode in ["corrupt","truncate","oversize","storfail"] {
                try Data(mode.utf8).write(to:remote.appendingPathComponent("mode"))
                do {
                    try ConsoleTransfer.send(package:local,destination:target,helper:helper,runner:ConversionRunner())
                    XCTFail("mode \(mode) must fail")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Remote folder:"), "\(mode): \(error.localizedDescription)")
                }
            }
            do {
                try Data("deny".utf8).write(to:remote.appendingPathComponent("mode"))
                try ConsoleTransfer.send(package:local,destination:target,helper:helper,runner:ConversionRunner())
                XCTFail("denied directory must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("No upload was started."), error.localizedDescription)
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
    func testCatalogCacheRoundTripAndFailClosedLoads() throws {
        let data=Data([1,2,3,4]),hash=FileDigest.sha256(data:data)
        let json: [String:Any] = ["version":1,"source":"Synthetic publisher","revision":"r1","license":"Synthetic test only",
            "entries":[["gameID":"SLUS12345","title":"Test","url":"https://example.invalid/config","sha256":hash,"bytes":4]]]
        let raw=try JSONSerialization.data(withJSONObject:json)
        let url=URL(string:"https://example.invalid/catalog.json")!
        try temporary { root in
            let date=Date(timeIntervalSince1970:1_700_000_000)
            try OnlineCatalogCache.save(data:raw,url:url,under:root,date:date)
            let snapshot=try XCTUnwrap(OnlineCatalogCache.load(url:url,under:root))
            XCTAssertEqual(snapshot.catalog.source,"Synthetic publisher")
            XCTAssertEqual(snapshot.catalog.revision,"r1")
            XCTAssertEqual(snapshot.catalog.entries.count,1)
            XCTAssertEqual(snapshot.retrievedAt,date)
            XCTAssertNil(OnlineCatalogCache.load(url:URL(string:"https://example.invalid/other.json")!,under:root))
            XCTAssertThrowsError(try OnlineCatalogCache.save(data:Data(repeating:0,count:OnlineCatalogCache.maximumBytes+1),url:url,under:root))
            XCTAssertThrowsError(try OnlineCatalogCache.save(data:Data("not a catalog".utf8),url:url,under:root))
            // A cache whose schema no longer validates loads as absent.
            var tampered=try JSONSerialization.jsonObject(with:Data(contentsOf:OnlineCatalogCache.file(for:url,under:root))) as! [String:Any]
            var inner=tampered["catalog"] as! [String:Any];inner["version"]=2;tampered["catalog"]=inner
            try JSONSerialization.data(withJSONObject:tampered).write(to:OnlineCatalogCache.file(for:url,under:root),options:.atomic)
            XCTAssertNil(OnlineCatalogCache.load(url:url,under:root))
            // An oversized cache file loads as absent and never allocates blindly.
            try Data(repeating:0,count:OnlineCatalogCache.maximumBytes+1).write(to:OnlineCatalogCache.file(for:url,under:root),options:.atomic)
            XCTAssertNil(OnlineCatalogCache.load(url:url,under:root))
            // A cache naming a different address loads as absent.
            try OnlineCatalogCache.save(data:raw,url:url,under:root)
            var renamed=try JSONSerialization.jsonObject(with:Data(contentsOf:OnlineCatalogCache.file(for:url,under:root))) as! [String:Any]
            renamed["url"]="https://example.invalid/impostor.json"
            try JSONSerialization.data(withJSONObject:renamed).write(to:OnlineCatalogCache.file(for:url,under:root),options:.atomic)
            XCTAssertNil(OnlineCatalogCache.load(url:url,under:root))
            try OnlineCatalogCache.save(data:raw,url:url,under:root)
            XCTAssertNotNil(OnlineCatalogCache.load(url:url,under:root))
            OnlineCatalogCache.remove(url:url,under:root)
            XCTAssertNil(OnlineCatalogCache.load(url:url,under:root))
        }
    }
    func testForeignCatalogEntryDownloadsNothing() throws {
        let data=Data([1,2,3,4]),hash=FileDigest.sha256(data:data)
        func catalog(_ url: String) throws -> OnlineConfigCatalog {
            let json: [String:Any] = ["version":1,"source":"Synthetic publisher","revision":"r1","license":"Synthetic test only",
                "entries":[["gameID":"SLUS12345","title":"Test","url":url,"sha256":hash,"bytes":4]]]
            return try OnlineConfigCatalog.decode(JSONSerialization.data(withJSONObject:json))
        }
        let first=try catalog("https://example.invalid/first"), second=try catalog("https://example.invalid/second")
        try temporary { root in
            XCTAssertThrowsError(try first.download(second.entries[0],into:root,runner:ConversionRunner()))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        }
    }
    func testInvalidPackageNeverReachesTheNetwork() throws {
        guard let path=ProcessInfo.processInfo.environment["PS2_TEST_HELPER"] else{throw XCTSkip("Set PS2_TEST_HELPER")}
        try temporary { root in
            let helper=URL(fileURLWithPath:path)
            let garbage=root.appendingPathComponent("garbage.pkg");try Data("not a package".utf8).write(to:garbage)
            let remote=root.appendingPathComponent("remote");try FileManager.default.createDirectory(at:remote,withIntermediateDirectories:false)
            // Port 1 is never contacted: local verification must fail first.
            let target=try FTPDestination(host:"127.0.0.1",port:1,directory:"/",username:"fixture",password:"test-only")
            XCTAssertThrowsError(try ConsoleTransfer.send(package:garbage,destination:target,helper:helper,runner:ConversionRunner()))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:remote.path),[])
        }
    }
}
