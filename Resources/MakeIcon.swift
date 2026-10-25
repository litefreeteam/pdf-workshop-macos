import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(red: 0.12, green: 0.48, blue: 0.41, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 215, yRadius: 215).fill()
NSColor.white.withAlphaComponent(0.16).setFill()
NSBezierPath(roundedRect: NSRect(x: 204, y: 208, width: 514, height: 624), xRadius: 48, yRadius: 48).fill()
NSColor(red: 0.94, green: 0.99, blue: 0.96, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 266, y: 162, width: 514, height: 624), xRadius: 48, yRadius: 48).fill()
NSColor(red: 0.66, green: 0.84, blue: 0.76, alpha: 1).setStroke()
for y in [674.0, 610.0, 546.0] {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 345, y: y)); line.line(to: NSPoint(x: y == 546 ? 575 : 692, y: y))
    line.lineWidth = 20; line.lineCapStyle = .round; line.stroke()
}
NSColor(red: 0.12, green: 0.48, blue: 0.41, alpha: 1).setStroke()
let cut = NSBezierPath()
cut.move(to: NSPoint(x: 290, y: 414)); cut.line(to: NSPoint(x: 752, y: 414))
cut.lineWidth = 9; cut.setLineDash([15, 16], count: 2, phase: 0); cut.stroke()
let scissors = NSBezierPath()
scissors.appendOval(in: NSRect(x: 342, y: 243, width: 90, height: 90))
scissors.appendOval(in: NSRect(x: 342, y: 339, width: 90, height: 90))
scissors.move(to: NSPoint(x: 414, y: 315)); scissors.line(to: NSPoint(x: 612, y: 423))
scissors.move(to: NSPoint(x: 414, y: 357)); scissors.line(to: NSPoint(x: 612, y: 249))
scissors.lineWidth = 18; scissors.lineCapStyle = .round; scissors.lineJoinStyle = .round; scissors.stroke()
image.unlockFocus()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@2x"
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
