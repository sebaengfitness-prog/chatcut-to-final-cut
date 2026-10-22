import AppKit
import Foundation
let directory = CommandLine.arguments[1]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    NSColor(calibratedRed: 0.065, green: 0.095, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s * 0.22, yRadius: s * 0.22).fill()
    NSColor(calibratedRed: 0.35, green: 0.91, blue: 0.79, alpha: 1).setFill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x:s*0.2, y:s*0.42)); arrow.line(to:NSPoint(x:s*0.58,y:s*0.42)); arrow.line(to:NSPoint(x:s*0.58,y:s*0.27)); arrow.line(to:NSPoint(x:s*0.82,y:s*0.5)); arrow.line(to:NSPoint(x:s*0.58,y:s*0.73)); arrow.line(to:NSPoint(x:s*0.58,y:s*0.58)); arrow.line(to:NSPoint(x:s*0.2,y:s*0.58)); arrow.close(); arrow.fill()
    NSColor(calibratedRed: 0.35, green: 0.91, blue: 0.79, alpha: 0.5).setFill()
    NSBezierPath(roundedRect: NSRect(x:s*0.2,y:s*0.18,width:s*0.18,height:s*0.055),xRadius:s*0.025,yRadius:s*0.025).fill()
    NSBezierPath(roundedRect: NSRect(x:s*0.41,y:s*0.18,width:s*0.18,height:s*0.055),xRadius:s*0.025,yRadius:s*0.025).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [Int:[String]] = [16:["icon_16x16.png"],32:["icon_16x16@2x.png","icon_32x32.png"],64:["icon_32x32@2x.png"],128:["icon_128x128.png"],256:["icon_128x128@2x.png","icon_256x256.png"],512:["icon_256x256@2x.png","icon_512x512.png"],1024:["icon_512x512@2x.png"]]
    for name in names[size]! { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name)) }
}
