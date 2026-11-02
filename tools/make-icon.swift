// SPDX-License-Identifier: GPL-3.0-or-later
// Original abstract app artwork; no game logo or game artwork is used.
import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for pixels in [16,32,64,128,256,512,1024] {
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    representation.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 210, yRadius: 210).fill()
    NSColor(calibratedRed: 0.85, green: 0.065, blue: 0.12, alpha: 1).setFill()
    let car = NSBezierPath(); car.move(to: NSPoint(x: 125,y: 390)); car.line(to: NSPoint(x: 235,y: 650)); car.line(to: NSPoint(x: 755,y: 650)); car.line(to: NSPoint(x: 900,y: 390)); car.close(); car.fill()
    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.19, alpha: 1).setFill()
    let glass = NSBezierPath(); glass.move(to: NSPoint(x: 295,y: 603)); glass.line(to: NSPoint(x: 715,y: 603)); glass.line(to: NSPoint(x: 780,y: 480)); glass.line(to: NSPoint(x: 245,y: 480)); glass.close(); glass.fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 175, y: 370, width: 150, height: 47), xRadius: 15,yRadius: 15).fill()
    NSBezierPath(roundedRect: NSRect(x: 700, y: 370, width: 150, height: 47), xRadius: 15,yRadius: 15).fill()
    let text = "C2" as NSString
    let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize: 192,weight: .heavy),.foregroundColor:NSColor.white]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (1024-size.width)/2,y: 105),withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    let png = representation.representation(using: .png, properties: [:])!
    let names: [String]
    switch pixels {
    case 16: names=["icon_16x16.png"]
    case 32: names=["icon_16x16@2x.png","icon_32x32.png"]
    case 64: names=["icon_32x32@2x.png"]
    case 128: names=["icon_128x128.png"]
    case 256: names=["icon_128x128@2x.png","icon_256x256.png"]
    case 512: names=["icon_256x256@2x.png","icon_512x512.png"]
    default: names=["icon_512x512@2x.png"]
    }
    for name in names { try png.write(to: output.appendingPathComponent(name)) }
}
