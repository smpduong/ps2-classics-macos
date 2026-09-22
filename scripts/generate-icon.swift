// SPDX-License-Identifier: GPL-3.0-only
import AppKit
let folder = URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale, n=CGFloat(pixels)
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:pixels*4,bitsPerPixel:32)!
        let context=NSGraphicsContext(bitmapImageRep:rep)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        let rect=NSRect(x:n*0.04,y:n*0.04,width:n*0.92,height:n*0.92)
        NSColor(calibratedRed:0.055,green:0.085,blue:0.15,alpha:1).setFill()
        NSBezierPath(roundedRect:rect,xRadius:n*0.20,yRadius:n*0.20).fill()
        NSColor(calibratedRed:0.25,green:0.63,blue:1,alpha:1).setStroke()
        for radius in [0.31,0.13,0.055] {
            let path=NSBezierPath(ovalIn:NSRect(x:n*(0.5-radius),y:n*(0.5-radius),width:n*radius*2,height:n*radius*2));path.lineWidth=n*0.026;path.stroke()
        }
        for angle in [0.4,0.6,3.54,3.74] {
            let path=NSBezierPath();path.move(to:NSPoint(x:n*(0.5+cos(angle)*0.17),y:n*(0.5+sin(angle)*0.17)))
            path.line(to:NSPoint(x:n*(0.5+cos(angle)*0.27),y:n*(0.5+sin(angle)*0.27)));path.lineWidth=n*0.018;path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name="icon_\(size)x\(size)"+(scale==2 ? "@2x" : "")+".png"
        try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name))
    }
}
