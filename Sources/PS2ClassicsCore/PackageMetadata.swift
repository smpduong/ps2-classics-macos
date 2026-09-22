// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import ImageIO

public enum PackageMetadata {
    public static func sfo(title: String, titleID: String) throws -> Data {
        guard title.utf8.count < 128, !title.contains("\0"), GameProject.validGameID(titleID) else { throw ConversionFailure(message: "Invalid package title or ID.") }
        let values: [(String, String?, UInt32, Int)] = [
            ("ATTRIBUTE",nil,0,4), ("BOOTABLE",nil,1,4), ("CATEGORY","2P",0,4),
            ("PARENTAL_LEVEL",nil,0,4), ("PS3_SYSTEM_VER","03.4000",0,8),
            ("REGION_DENY",nil,0,4), ("TITLE",title,0,128), ("TITLE_ID",titleID,0,16)]
        var keys = Data(), index = Data(), data = Data()
        for (key,text,number,capacity) in values {
            index.le(UInt64(keys.count), 2); index.le(text == nil ? 1028 : 516,2)
            let bytes = text.map { Data($0.utf8) + Data([0]) }
            index.le(UInt64(bytes?.count ?? 4),4); index.le(UInt64(capacity),4); index.le(UInt64(data.count),4)
            keys.append(contentsOf: key.utf8); keys.append(0)
            if let bytes = bytes { data.append(bytes); data.append(Data(count: capacity - bytes.count)) }
            else { data.le(UInt64(number),4) }
        }
        while keys.count % 4 != 0 { keys.append(0) }
        var header = Data([0,80,83,70]); header.le(257,4); header.le(UInt64(20+index.count),4)
        header.le(UInt64(20+index.count+keys.count),4); header.le(UInt64(values.count),4)
        return header + index + keys + data
    }

    public static func config(_ original: Data?, gameID: String, count: Int, discIndex: Int) throws -> Data? {
        guard count > 1 else { return original }
        var data = original ?? Data()
        // Recognize the exact 17-byte title trailer, not any arbitrary run of zeroes.
        if data.count >= 17 {
            let tail = Data(data.suffix(17))
            let id = String(decoding: tail[4..<14], as: UTF8.self)
            if tail.prefix(4) == Data(count: 4), tail[14] == 0,
               id.range(of: #"^[A-Z]{4}-[0-9]{5}$"#, options: .regularExpression) != nil { data.removeLast(17) }
        }
        data.append(Data(count: 4)); data.append(contentsOf: (String(gameID.prefix(4))+"-"+gameID.suffix(5)).utf8)
        data.append(contentsOf: [0,UInt8(count),UInt8(discIndex)])
        return data
    }

    public static func validateSound(_ bytes: Data) throws {
        func bad() -> ConversionFailure { ConversionFailure(message:"Sound must be an existing ATRAC3 RIFF/WAVE file, not renamed PCM audio.") }
        func little(_ p:Int,_ n:Int)->Int { (0..<n).reduce(0) { $0 | Int(bytes[p+$1]) << ($1*8) } }
        guard bytes.count >= 12, bytes.prefix(4)==Data("RIFF".utf8), bytes[8..<12]==Data("WAVE".utf8), little(4,4)+8 == bytes.count else { throw bad() }
        var offset=12, codec=false, payload=false
        while offset+8 <= bytes.count {
            let size=little(offset+4,4), start=offset+8
            guard size <= bytes.count-start else { throw bad() }
            let type=bytes[offset..<offset+4]
            if type==Data("fmt ".utf8) { guard size>=16, little(start,2)==0x270 else { throw bad() }; codec=true }
            if type==Data("data".utf8) { payload=size>0 }
            offset=start+size+(size%2)
        }
        guard codec,payload,offset==bytes.count else { throw bad() }
    }

    public static func artwork(source: URL?, width: Int, height: Int, crop: Bool, title: String) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width*4, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ConversionFailure(message: "Could not create artwork.")
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = NSRect(x:0,y:0,width:width,height:height)
        NSColor(calibratedRed:0.06,green:0.09,blue:0.16,alpha:1).setFill(); bounds.fill()
        if let source = source {
            let bytes = try FileDigest.small(source, maximum: 32*1024*1024)
            guard let imageSource = CGImageSourceCreateWithData(bytes as CFData,nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(imageSource,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1920,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else {
                throw ConversionFailure(message: "Artwork must be a readable PNG or JPEG image.")
            }
            let image = NSImage(cgImage: cg, size: NSSize(width:cg.width,height:cg.height))
            let x = CGFloat(width)/CGFloat(cg.width), y = CGFloat(height)/CGFloat(cg.height)
            let scale = crop ? max(x,y) : min(x,y)
            let size = NSSize(width:CGFloat(cg.width)*scale,height:CGFloat(cg.height)*scale)
            image.draw(in: NSRect(x:(CGFloat(width)-size.width)/2,y:(CGFloat(height)-size.height)/2,width:size.width,height:size.height))
        } else {
            NSColor(calibratedRed:0.26,green:0.61,blue:0.95,alpha:1).setFill()
            NSRect(x:CGFloat(width)*0.08,y:CGFloat(height)*0.25,width:CGFloat(width)*0.02,height:CGFloat(height)*0.5).fill()
            let font = NSFont.systemFont(ofSize:CGFloat(height)*0.105,weight:.semibold)
            (title as NSString).draw(in:NSRect(x:CGFloat(width)*0.15,y:CGFloat(height)*0.26,width:CGFloat(width)*0.76,height:CGFloat(height)*0.48),withAttributes:[.font:font,.foregroundColor:NSColor.white])
        }
        guard let png = bitmap.representation(using:.png,properties:[:]) else { throw ConversionFailure(message:"Artwork encoding failed.") }
        return png
    }
}
private extension Data {
    mutating func le(_ value: UInt64, _ count: Int) { for i in 0..<count { append(UInt8(truncatingIfNeeded: value >> (i*8))) } }
}
