import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("Bozhou.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 215, yRadius: 215)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.24); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.40, blue: 0.57, alpha: 1),
               ending: NSColor(srgbRed: 0.025, green: 0.13, blue: 0.23, alpha: 1))!.draw(in: background, angle: -65)
    NSShadow().set()
    NSColor.white.withAlphaComponent(0.15).setStroke(); background.lineWidth = 3; background.stroke()
    let sail = NSBezierPath()
    sail.move(to: NSPoint(x: 505, y: 784))
    sail.curve(to: NSPoint(x: 265, y: 425), controlPoint1: NSPoint(x: 472, y: 650), controlPoint2: NSPoint(x: 337, y: 524))
    sail.line(to: NSPoint(x: 505, y: 425)); sail.close()
    NSGradient(starting: NSColor(srgbRed: 0.62, green: 1, blue: 0.87, alpha: 1),
               ending: NSColor(srgbRed: 0.23, green: 0.78, blue: 0.72, alpha: 1))!.draw(in: sail, angle: -90)
    let right = NSBezierPath()
    right.move(to: NSPoint(x: 547, y: 724)); right.line(to: NSPoint(x: 547, y: 425)); right.line(to: NSPoint(x: 756, y: 425)); right.close()
    NSColor(srgbRed: 0.80, green: 0.98, blue: 0.94, alpha: 1).setFill(); right.fill()
    let hull = NSBezierPath()
    hull.move(to: NSPoint(x: 241, y: 370)); hull.line(to: NSPoint(x: 781, y: 370))
    hull.curve(to: NSPoint(x: 654, y: 264), controlPoint1: NSPoint(x: 746, y: 316), controlPoint2: NSPoint(x: 714, y: 264))
    hull.line(to: NSPoint(x: 357, y: 264))
    hull.curve(to: NSPoint(x: 241, y: 370), controlPoint1: NSPoint(x: 300, y: 264), controlPoint2: NSPoint(x: 265, y: 333))
    hull.close(); NSColor(srgbRed: 0.30, green: 0.86, blue: 0.77, alpha: 1).setFill(); hull.fill()
    let prompt = NSBezierPath(); prompt.move(to: NSPoint(x: 402, y: 338)); prompt.line(to: NSPoint(x: 429, y: 316)); prompt.line(to: NSPoint(x: 402, y: 294))
    prompt.lineWidth = 12; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
    NSColor(srgbRed: 0.04, green: 0.25, blue: 0.34, alpha: 1).setStroke(); prompt.stroke()
    let cursor = NSBezierPath(); cursor.move(to: NSPoint(x: 456, y: 296)); cursor.line(to: NSPoint(x: 493, y: 296)); cursor.lineWidth = 11; cursor.lineCapStyle = .round; cursor.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try draw(size: 1024).write(to: root.appendingPathComponent("Bozhou.png"))
