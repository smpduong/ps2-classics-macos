// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CoreGraphics
import ImageIO
@testable import PS2ClassicsCore

final class SoftwareManualTests: XCTestCase {
    func temporary(_ body: (URL) throws -> Void) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try body(root)
    }
    func pdf(_ url:URL) throws {
        var box=CGRect(x:0,y:0,width:960,height:768)
        let context=try XCTUnwrap(CGContext(url as CFURL,mediaBox:&box,nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[0,0,1,1])!);context.fill(box)
        context.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[1,0,0,1])!);context.fill(CGRect(x:0,y:384,width:960,height:384))
        context.endPDFPage();context.closePDF()
    }
    // Independent BC1 point decoder, not the encoder's palette helpers.
    func pixel(_ data:Data,_ x:Int,_ y:Int)->[Int] {
        let off=8+((y/4)*240+x/4)*8
        let a=UInt16(data[off])|UInt16(data[off+1])<<8,b=UInt16(data[off+2])|UInt16(data[off+3])<<8
        func rgb(_ n:UInt16)->[Int]{[Int((n>>11)&31)*255/31,Int((n>>5)&63)*255/63,Int(n&31)*255/31]}
        let ca=rgb(a),cb=rgb(b)
        let bits=(0..<4).reduce(UInt32(0)){$0|UInt32(data[off+4+$1])<<($1*8)}
        let i=Int((bits>>(((y%4)*4+x%4)*2))&3)
        if i==0{return ca};if i==1{return cb}
        return (0..<3).map{ i==2 ? (2*ca[$0]+cb[$0])/3 : (ca[$0]+2*cb[$0])/3 }
    }
    func testPDFPageGeometryColourOrientationAndProjectRoundTrip() throws {
        try temporary { root in
            let source=root.appendingPathComponent("manual.pdf"), directory=root.appendingPathComponent("CONTENT")
            try pdf(source);let before=try FileDigest.sha256(source)
            let hashes=try SoftwareManual.build(source:source,directory:directory)
            XCTAssertEqual(try String(contentsOf:directory.appendingPathComponent("manual.idx")),"001.dxt\n")
            let page=try Data(contentsOf:directory.appendingPathComponent("001.dxt"))
            XCTAssertEqual(page.count,SoftwareManual.pageBytes)
            XCTAssertEqual(pixel(page,100,100),[255,0,0])
            XCTAssertEqual(pixel(page,100,650),[0,0,255])
            XCTAssertEqual(hashes["manual/001.dxt"],FileDigest.sha256(data:page))
            XCTAssertEqual(try FileDigest.sha256(source),before)
            var project=GameProject();project.manual=source
            XCTAssertEqual(try JSONDecoder().decode(GameProject.self,from:JSONEncoder().encode(project)).manual,source)
            XCTAssertEqual(QueuedJobIdentity(jobID:UUID(),project:project).assetPaths["manual"],source.path)
        }
    }
    func testImageManualAndLegacyProject() throws {
        try temporary { root in
            let source=root.appendingPathComponent("page.png"),dir=root.appendingPathComponent("CONTENT")
            let context=try XCTUnwrap(CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[0,1,0,1])!)
            context.fill(CGRect(x:0,y:0,width:32,height:32))
            let image=try XCTUnwrap(context.makeImage())
            let output=try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL,"public.png" as CFString,1,nil))
            CGImageDestinationAddImage(output,image,nil);XCTAssertTrue(CGImageDestinationFinalize(output))
            _ = try SoftwareManual.build(source:source,directory:dir)
            let page=try Data(contentsOf:dir.appendingPathComponent("001.dxt"))
            XCTAssertEqual(pixel(page,480,384),[0,255,0])
            XCTAssertEqual(pixel(page,10,384),[255,255,255]) // letterboxing
            var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(GameProject())) as! [String:Any]
            json.removeValue(forKey:"manual")
            XCTAssertNil(try JSONDecoder().decode(GameProject.self,from:JSONSerialization.data(withJSONObject:json)).manual)
        }
    }
    func testMalformedManualAndCancellationRemoveOnlyOwnFiles() throws {
        try temporary {root in
            let source=root.appendingPathComponent("manual.pdf"),dir=root.appendingPathComponent("CONTENT")
            try Data("%PDF-corrupt".utf8).write(to:source)
            XCTAssertThrowsError(try SoftwareManual.build(source:source,directory:dir))
            XCTAssertFalse(FileManager.default.fileExists(atPath:dir.path))
            try pdf(source)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
            let sentinel=dir.appendingPathComponent("keep.txt");try Data("preserve".utf8).write(to:sentinel)
            XCTAssertThrowsError(try SoftwareManual.build(source:source,directory:dir))
            XCTAssertEqual(try String(contentsOf:sentinel),"preserve")
            try FileManager.default.removeItem(at:dir)
            let runner=ConversionRunner()
            XCTAssertThrowsError(try SoftwareManual.build(source:source,directory:dir,cancelled:{try runner.checkCancellation()}){_ in runner.cancel()})
            XCTAssertFalse(FileManager.default.fileExists(atPath:dir.path))
        }
    }
    /// A /Rotate 90 page must render upright (red moves top -> right), not
    /// reuse the unrotated layout. Locks in the independently probed behavior.
    func testRotatedPDFPageRendersUpright() throws {
        func rawPDF(rotate: Int?) -> Data {
            let stream=Data("0 0 1 rg 0 0 960 768 re f 1 0 0 rg 0 384 960 384 re f".utf8)
            var objects=[Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
                         Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)]
            var page="<< /Type /Page /Parent 2 0 R /MediaBox [0 0 960 768]"
            if let rotate { page+=" /Rotate \(rotate)" }
            page+=" /Resources << >> /Contents 4 0 R >>"
            objects.append(Data(page.utf8))
            objects.append(Data("<< /Length \(stream.count) >>\nstream\n".utf8)+stream+Data("\nendstream".utf8))
            var result=Data("%PDF-1.4\n".utf8);var offsets=[0]
            for (i,obj) in objects.enumerated() {
                offsets.append(result.count)
                result+=Data("\(i+1) 0 obj\n".utf8)+obj+Data("\nendobj\n".utf8)
            }
            let start=result.count
            result+=Data("xref\n0 5\n0000000000 65535 f \n".utf8)
            for off in offsets.dropFirst() { result+=Data(String(format:"%010d 00000 n \n",off).utf8) }
            return result+Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8)
        }
        try temporary { root in
            let source=root.appendingPathComponent("rotated.pdf"),dir=root.appendingPathComponent("CONTENT")
            try rawPDF(rotate:90).write(to:source)
            _ = try SoftwareManual.build(source:source,directory:dir)
            let page=try Data(contentsOf:dir.appendingPathComponent("001.dxt"))
            XCTAssertEqual(pixel(page,260,384),[0,0,255])
            XCTAssertEqual(pixel(page,700,384),[255,0,0])
        }
    }
    func testOversizedPDFAndAnimatedImageAndSymlinkAreRejected() throws {
        try temporary { root in
            // 101 pages fails fast at validation; nothing is staged.
            let source=root.appendingPathComponent("manual.pdf"),dir=root.appendingPathComponent("CONTENT")
            var box=CGRect(x:0,y:0,width:960,height:768)
            let context=try XCTUnwrap(CGContext(source as CFURL,mediaBox:&box,nil))
            for _ in 0..<101 { context.beginPDFPage(nil);context.endPDFPage() }
            context.closePDF()
            do {
                try SoftwareManual.build(source:source,directory:dir)
                XCTFail("a 101-page PDF must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("1–100"),error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:dir.path))
            // A two-frame image must not silently contribute its first frame.
            let animated=root.appendingPathComponent("animated.gif"),animatedDir=root.appendingPathComponent("ANIMATED")
            let frame=try XCTUnwrap(CGContext(data:nil,width:16,height:16,bitsPerComponent:8,bytesPerRow:64,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            frame.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[0,1,0,1])!)
            frame.fill(CGRect(x:0,y:0,width:16,height:16))
            let output=try XCTUnwrap(CGImageDestinationCreateWithURL(animated as CFURL,"com.compuserve.gif" as CFString,2,nil))
            CGImageDestinationAddImage(output,try XCTUnwrap(frame.makeImage()),nil)
            CGImageDestinationAddImage(output,try XCTUnwrap(frame.makeImage()),nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
            do {
                try SoftwareManual.build(source:animated,directory:animatedDir)
                XCTFail("a multi-frame image must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("single PNG/JPEG"),error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:animatedDir.path))
            // A symlinked source is never followed for manual input.
            try pdf(root.appendingPathComponent("real.pdf"))
            let link=root.appendingPathComponent("link.pdf")
            try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root.appendingPathComponent("real.pdf"))
            XCTAssertThrowsError(try SoftwareManual.build(source:link,directory:root.appendingPathComponent("LINK")))
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("LINK").path))
        }
    }
}
