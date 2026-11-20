import AppKit

// Renders the app icon (cyan-to-violet gradient tile with white waveform bars) and writes AppIcon.icns.
let out = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
// The macOS icon grid: an 824 pt tile centred on the 1024 canvas, with a soft shadow under it.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
rgb(0x4C7DFF).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(0x62E6FF), rgb(0x4F86FF), rgb(0x8A5CFF), rgb(0xA35BFF)],
           atLocations: [0, 0.42, 0.82, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -45)
// A gentle light from the top and a faint inner edge.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: tile, angle: -90)
NSColor.white.withAlphaComponent(0.18).setStroke()
let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 183, yRadius: 183)
edge.lineWidth = 6
edge.stroke()
// Waveform: five rounded white bars, like a voice peaking in the middle.
let heights: [CGFloat] = [0.36, 0.72, 1.0, 0.62, 0.34]
let barWidth: CGFloat = 64, gap: CGFloat = 48, tallest: CGFloat = 440
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = rgb(0x2A1F7A, 0.35)
glow.shadowOffset = NSSize(width: 0, height: -6)
glow.shadowBlurRadius = 18
glow.set()
NSColor.white.setFill()
for (i, h) in heights.enumerated() {
    let height = tallest * h
    let x = 512 - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
    NSBezierPath(roundedRect: NSRect(x: x, y: 512 - height / 2, width: barWidth, height: height),
                 xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
}
NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: tmp.appendingPathComponent("\(name).png"))
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", tmp.path, "-o", out]
task.launch()
task.waitUntilExit()
print("icon written to \(out), status \(task.terminationStatus)")
