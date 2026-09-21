import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let factor = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 64,y: 64,width: 896,height: 896), xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(srgbRed: 0.16,green: 0.22,blue: 0.29,alpha: 1), ending: NSColor(srgbRed: 0.035,green: 0.055,blue: 0.08,alpha: 1))!.draw(in: tile, angle: -90)
    let bar = NSBezierPath(roundedRect: NSRect(x: 166,y: 276,width: 692,height: 190),xRadius: 60,yRadius: 60)
    NSColor(srgbRed: 0.025,green: 0.035,blue: 0.055,alpha: 1).setFill(); bar.fill()
    NSColor(srgbRed: 0.24,green: 0.87,blue: 0.73,alpha: 1).setStroke()
    let wave = NSBezierPath(); wave.lineWidth = 24; wave.lineJoinStyle = .round; wave.lineCapStyle = .round
    wave.move(to: NSPoint(x: 226,y: 371))
    for point in [NSPoint(x:290,y:371),NSPoint(x:324,y:412),NSPoint(x:374,y:324),NSPoint(x:421,y:371),NSPoint(x:470,y:371)] { wave.line(to: point) }; wave.stroke()
    NSColor.white.setStroke()
    for x in [CGFloat(334),CGFloat(618)] {
        let bracket = NSBezierPath(); bracket.lineWidth = 38; bracket.lineCapStyle = .round; bracket.lineJoinStyle = .round
        bracket.move(to: NSPoint(x:x+72,y:704)); bracket.line(to: NSPoint(x:x,y:632)); bracket.line(to: NSPoint(x:x+72,y:560))
        if x > 500 { let mirror=NSAffineTransform(); mirror.translateX(by: 2*x+72,yBy: 0);mirror.scaleX(by: -1,yBy: 1);bracket.transform(using:mirror as AffineTransform) }
        bracket.stroke()
    }
    NSColor(srgbRed: 0.24,green: 0.87,blue: 0.73,alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x:546,y:343,width:244,height:56),xRadius:28,yRadius:28).fill()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
